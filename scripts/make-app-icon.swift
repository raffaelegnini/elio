// Renders the macOS app icon: a glowing neural network around a bright core, on a dark squircle.
// Usage: swift make-app-icon.swift <out.icns>
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-app-icon <out.icns>\n".utf8))
    exit(1)
}

let yellow = NSColor(red: 1, green: 0.83, blue: 0.38, alpha: 1)
let amber = NSColor(red: 0.98, green: 0.58, blue: 0.16, alpha: 1)

/// Nodes in unit coordinates (centre = 0,0, radius ≈ 1): an inner ring and an organic outer ring.
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

struct Net {
    var nodes: [CGPoint] = [.zero]
    var edges: [(Int, Int)] = []
    var size: [CGFloat] = [1]

    init() {
        let inner = 6, outer = 11
        for i in 0..<inner {
            let a = CGFloat(i) / CGFloat(inner) * 2 * .pi + 0.3
            let r: CGFloat = 0.42 + (i % 2 == 0 ? 0.04 : -0.03)
            nodes.append(CGPoint(x: cos(a) * r, y: sin(a) * r)); size.append(0.55)
        }
        let wobble: [CGFloat] = [0.06, -0.05, 0.03, -0.08, 0.07, -0.02, 0.05, -0.06, 0.02, -0.04, 0.08]
        for i in 0..<outer {
            let a = CGFloat(i) / CGFloat(outer) * 2 * .pi + 0.05
            let r = 0.86 + wobble[i]
            nodes.append(CGPoint(x: cos(a) * r, y: sin(a) * r)); size.append(i % 3 == 0 ? 0.5 : 0.36)
        }
        for i in 1...inner { edges.append((0, i)); edges.append((i, i % inner + 1)) }
        // Each outer neuron links to its two nearest inner neurons and to the next one around the ring.
        for j in 0..<outer {
            let o = 1 + inner + j
            let nearest = (1...inner).sorted { dist(nodes[$0], nodes[o]) < dist(nodes[$1], nodes[o]) }
            edges.append((nearest[0], o))
            if j % 3 != 1 { edges.append((nearest[1], o)) }
            edges.append((o, 1 + inner + (j + 1) % outer))
        }
    }
}

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()

    // Apple grid: 824/1024 body with ~22% corner radius, room left for the drop shadow.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.12, green: 0.11, blue: 0.15, alpha: 1).cgColor,
        NSColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    let c = CGPoint(x: body.midX, y: body.midY)
    let glow = CGGradient(colorsSpace: space, colors: [
        yellow.withAlphaComponent(0.30).cgColor, amber.withAlphaComponent(0.08).cgColor, amber.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * 0.6, options: [])

    let net = Net()
    let scale = body.width * 0.36
    func pt(_ i: Int) -> CGPoint { CGPoint(x: c.x + net.nodes[i].x * scale, y: c.y + net.nodes[i].y * scale) }
    // Small sizes: fewer, bolder strokes so the network still reads at 16–32 px.
    let small = size <= 64

    // Synapses: brighter near the core, fading outwards.
    ctx.setLineCap(.round)
    for (a, b) in net.edges {
        let fromCore = a == 0
        if small && !fromCore && b > 7 && a > 0 && (a + b) % 2 == 1 { continue }
        let p1 = pt(a), p2 = pt(b)
        ctx.saveGState()
        ctx.setLineWidth(size * (small ? 0.022 : (fromCore ? 0.011 : 0.007)))
        ctx.setShadow(offset: .zero, blur: size * 0.015, color: yellow.withAlphaComponent(0.7).cgColor)
        ctx.replacePathWithStrokedPath()
        ctx.move(to: p1); ctx.addLine(to: p2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let line = CGGradient(colorsSpace: space, colors: [
            yellow.withAlphaComponent(fromCore ? 0.95 : 0.75).cgColor, amber.withAlphaComponent(0.45).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(line, start: p1, end: p2, options: [])
        ctx.restoreGState()
    }

    // Neurons: halo plus a solid centre.
    for i in net.nodes.indices.reversed() {
        let p = pt(i)
        let r = size * 0.024 * net.size[i] * (small ? 1.6 : 1)
        let halo = CGGradient(colorsSpace: space, colors: [
            yellow.withAlphaComponent(0.55).cgColor, yellow.withAlphaComponent(0).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(halo, startCenter: p, startRadius: 0, endCenter: p, endRadius: r * 3.2, options: [])
        ctx.setFillColor((i == 0 ? NSColor.white : yellow).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    // The core: hot white centre bleeding into yellow.
    let core = CGGradient(colorsSpace: space, colors: [
        NSColor.white.cgColor, yellow.cgColor, amber.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 0.35, 1])!
    ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: body.width * 0.13, options: [])

    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(size * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", args[1]]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(p.terminationStatus)
