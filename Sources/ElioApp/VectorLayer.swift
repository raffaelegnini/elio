import AppKit
import QuartzCore
import SwiftUI

// Live animations (the orb, the neural network) are described frame by frame as a `VectorFrame`:
// a few batched paths per colour, radial glows and cached images. A Core Animation view renders it
// from a display link — no SwiftUI view update per frame, the GPU composites the layers — and the same
// frame can be drawn into a SwiftUI Canvas for snapshots. SwiftUI's TimelineView + Canvas re-evaluated
// the view graph and re-laid out text on every frame: ~35% CPU at 24 fps for the dashboard.

/// A paint: colour (8-bit RGBA) plus stroke width in tenths of a point (0 = fill). Quantised so
/// thousands of segments collapse into a handful of paths.
struct Ink: Hashable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    var width: UInt16

    @MainActor
    init(_ color: Color, opacity: Double = 1, width: CGFloat = 0) {
        let c = ColorCache.rgba(color)
        r = UInt8(c.r * 255); g = UInt8(c.g * 255); b = UInt8(c.b * 255)
        a = UInt8(max(0, min(1, c.a * opacity)) * 255)
        self.width = UInt16(max(0, (width * 10).rounded()))
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
    var lineWidth: CGFloat { CGFloat(width) / 10 }
    var isFill: Bool { width == 0 }
}

/// Drawing order: everything in a lower layer is under everything in a higher one.
enum Stratum: Int, CaseIterable { case back, glow, body, front, icons, labels }

struct Glow {
    var center: CGPoint
    var radius: CGFloat
    var colors: [CGColor]
}

/// Text or an SF Symbol rendered once to a bitmap and reused.
struct ImageSpec {
    enum Content { case text(String, size: CGFloat, color: NSColor), symbol(String, color: NSColor) }
    let key: String
    let content: Content
}

struct PlacedImage {
    var spec: ImageSpec
    /// Either fitted in a rect (icons, aspect kept) or at a point with an anchor (labels, natural size).
    var rect: CGRect?
    var point: CGPoint = .zero
    var anchor: UnitPoint = .center
    var stratum: Stratum = .labels

    func frame(for size: CGSize) -> CGRect {
        guard let rect else {
            return CGRect(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y, width: size.width, height: size.height)
        }
        let k = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let w = size.width * k, h = size.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

struct VectorFrame {
    var paths: [Stratum: [Ink: CGMutablePath]] = [:]
    var glows: [Glow] = []
    var images: [PlacedImage] = []

    mutating func add(_ path: CGPath, _ ink: Ink, _ stratum: Stratum = .body) {
        if paths[stratum] == nil { paths[stratum] = [:] }
        if let existing = paths[stratum]![ink] { existing.addPath(path) } else {
            let p = CGMutablePath()
            p.addPath(path)
            paths[stratum]![ink] = p
        }
    }

    mutating func segment(_ a: CGPoint, _ b: CGPoint, _ ink: Ink, _ stratum: Stratum = .back) {
        if paths[stratum] == nil { paths[stratum] = [:] }
        let p = paths[stratum]![ink] ?? { let m = CGMutablePath(); paths[stratum]![ink] = m; return m }()
        p.move(to: a)
        p.addLine(to: b)
    }

    mutating func circle(_ c: CGPoint, _ r: CGFloat, _ ink: Ink, _ stratum: Stratum = .body) {
        if paths[stratum] == nil { paths[stratum] = [:] }
        let p = paths[stratum]![ink] ?? { let m = CGMutablePath(); paths[stratum]![ink] = m; return m }()
        p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// For snapshots: the same frame through a SwiftUI Canvas.
    @MainActor
    func draw(in ctx: inout GraphicsContext) {
        for stratum in Stratum.allCases {
            if stratum == .glow {
                for g in glows {
                    let colors = g.colors.map { Color(cgColor: $0) }
                    ctx.fill(Path(ellipseIn: CGRect(x: g.center.x - g.radius, y: g.center.y - g.radius, width: g.radius * 2, height: g.radius * 2)),
                             with: .radialGradient(Gradient(colors: colors), center: g.center, startRadius: 0, endRadius: g.radius))
                }
            }
            for (ink, path) in paths[stratum] ?? [:] {
                let color = Color(cgColor: ink.cgColor)
                if ink.isFill { ctx.fill(Path(path), with: .color(color)) } else { ctx.stroke(Path(path), with: .color(color), lineWidth: ink.lineWidth) }
            }
            for img in images where img.stratum == stratum {
                guard let (cg, size) = ImageCache.shared.image(img.spec) else { continue }
                ctx.draw(Image(decorative: cg, scale: ImageCache.scale), in: img.frame(for: size))
            }
        }
    }
}

// MARK: - Caches

@MainActor
enum ColorCache {
    private static var cache: [Color: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)] = [:]

    static func rgba(_ color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        if let c = cache[color] { return c }
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let c = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
        if cache.count > 200 { cache.removeAll() }
        cache[color] = c
        return c
    }
}

/// Bitmaps for labels and icons, rendered once at Retina scale.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    static let scale: CGFloat = 2
    private var images: [String: (CGImage, CGSize)] = [:]

    func size(_ spec: ImageSpec) -> CGSize { image(spec)?.1 ?? .zero }

    func image(_ spec: ImageSpec) -> (CGImage, CGSize)? {
        if let hit = images[spec.key] { return hit }
        guard let made = render(spec) else { return nil }
        if images.count > 2000 { images.removeAll() }
        images[spec.key] = made
        return made
    }

    private func render(_ spec: ImageSpec) -> (CGImage, CGSize)? {
        let s = Self.scale
        switch spec.content {
        case .text(let string, let size, let color):
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            let bounds = text.boundingRect(with: CGSize(width: 1000, height: 100), options: [.usesLineFragmentOrigin])
            let pt = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height) + 2)
            return bitmap(pt, scale: s) { _ in text.draw(at: NSPoint(x: 1, y: 1)) }
        case .symbol(let name, let color):
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 32, weight: .medium)) else { return nil }
            let pt = base.size
            return bitmap(pt, scale: s) { rect in
                base.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
            }
        }
    }

    private func bitmap(_ pt: CGSize, scale: CGFloat, _ draw: (NSRect) -> Void) -> (CGImage, CGSize)? {
        let w = Int(pt.width * scale), h = Int(pt.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(NSRect(origin: .zero, size: pt))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { ($0, pt) }
    }
}

// MARK: - Core Animation renderer

/// Renders a `VectorFrame` per display refresh with pooled layers: one shape layer per ink,
/// gradient layers for glows, image layers for labels and icons. Only geometry changes per frame.
final class VectorLayerView: NSView {
    var fps: Double = 60 { didSet { updateLink() } }
    var render: ((Double) -> VectorFrame)?

    private var link: CADisplayLink?
    private let strata: [Stratum: CALayer] = Dictionary(uniqueKeysWithValues: Stratum.allCases.map { ($0, CALayer()) })
    private var shapes: [Stratum: [Ink: CAShapeLayer]] = [:]
    private var glowPool: [CAGradientLayer] = []
    private var imagePool: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting (layer first, then wantsLayer): AppKit leaves the tree to us.
        layer = CALayer()
        wantsLayer = true
        layer?.isGeometryFlipped = true      // SwiftUI coordinates: y grows downwards
        for s in Stratum.allCases { layer?.addSublayer(strata[s]!) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
        tick()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        for s in strata.values { s.contentsScale = scale }
    }

    private func updateLink() {
        guard window != nil, fps > 0 else {
            link?.invalidate()
            link = nil
            return
        }
        if link == nil {
            link = displayLink(target: self, selector: #selector(step))
            link?.add(to: .main, forMode: .common)
        }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 30)), maximum: Float(fps), preferred: Float(fps))
    }

    @objc private func step(_ link: CADisplayLink) { tick(at: link.targetTimestamp) }

    /// Draws one frame (also called once when parameters change while paused).
    func tick(at mediaTime: CFTimeInterval? = nil) {
        guard let render, bounds.width > 0 else { return }
        let frame = render(Date().timeIntervalSinceReferenceDate)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(frame)
        CATransaction.commit()
    }

    private func apply(_ frame: VectorFrame) {
        let scale = window?.backingScaleFactor ?? 2
        for s in Stratum.allCases {
            let container = strata[s]!
            container.frame = bounds
            var pool = shapes[s] ?? [:]
            let wanted = frame.paths[s] ?? [:]
            for (ink, layer) in pool where wanted[ink] == nil {
                layer.removeFromSuperlayer()
                pool[ink] = nil
            }
            for (ink, path) in wanted {
                let layer = pool[ink] ?? {
                    let l = CAShapeLayer()
                    l.contentsScale = scale
                    if ink.isFill { l.fillColor = ink.cgColor; l.strokeColor = nil } else {
                        l.fillColor = nil; l.strokeColor = ink.cgColor; l.lineWidth = ink.lineWidth; l.lineCap = .round
                    }
                    container.addSublayer(l)
                    pool[ink] = l
                    return l
                }()
                layer.path = path
            }
            shapes[s] = pool
        }

        // Glows.
        let glowContainer = strata[.glow]!
        while glowPool.count < frame.glows.count {
            let g = CAGradientLayer()
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            glowContainer.insertSublayer(g, at: 0)
            glowPool.append(g)
        }
        for (i, g) in glowPool.enumerated() {
            guard i < frame.glows.count else { g.isHidden = true; continue }
            let glow = frame.glows[i]
            g.isHidden = false
            g.frame = CGRect(x: glow.center.x - glow.radius, y: glow.center.y - glow.radius, width: glow.radius * 2, height: glow.radius * 2)
            g.colors = glow.colors
        }

        // Images (labels, icons).
        var used = 0
        for img in frame.images {
            guard let (cg, size) = ImageCache.shared.image(img.spec) else { continue }
            if used == imagePool.count {
                let l = CALayer()
                l.contentsGravity = .resize
                imagePool.append(l)
            }
            let l = imagePool[used]
            used += 1
            let parent = strata[img.stratum]!
            if l.superlayer !== parent { parent.addSublayer(l) }
            if l.contents as! CGImage? !== cg { l.contents = cg }
            l.contentsScale = ImageCache.scale
            l.isHidden = false
            l.frame = img.frame(for: size)
        }
        for l in imagePool[used...] { l.isHidden = true }
    }
}

/// SwiftUI wrapper. `render` is called on every display refresh with the current time.
struct VectorLayer: NSViewRepresentable {
    var fps: Double
    var render: (Double) -> VectorFrame

    func makeNSView(context: Context) -> VectorLayerView {
        let v = VectorLayerView(frame: .zero)
        v.render = render
        v.fps = fps
        return v
    }

    func updateNSView(_ v: VectorLayerView, context: Context) {
        v.render = render
        v.fps = fps
        // Paused (window behind others): still reflect the new state once.
        if fps <= 0 { v.tick() }
    }
}

extension EnvironmentValues {
    /// Off for snapshots (ImageRenderer can't draw AppKit views): animations draw through a Canvas instead.
    @Entry var liveLayers = true
}
