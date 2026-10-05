import AppKit
import ElioCore
import SwiftUI
import WebKit

/// A dashboard panel the user can move by dragging it anywhere and resize from any edge or corner
/// (no buttons). Position and size are remembered.
///
/// Layout trick: once resized, the panel keeps its original footprint in the dashboard layout and
/// draws its new size from the top-left corner, so neighbours don't jump and left/top resizing is
/// exact (the offset moves the origin, the size grows the other way).
struct Movable<Content: View>: View {
    let id: String
    var dormant = false
    @ViewBuilder let content: Content
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var size: CGSize?
    @State private var base: CGSize?
    @State private var resizeStart: (size: CGSize, offset: CGSize)?
    @State private var measured: CGSize = .zero

    static var minSize: CGSize { CGSize(width: 200, height: 90) }
    static func key(_ id: String) -> String { "elio.panel.\(id)" }
    static func sizeKey(_ id: String) -> String { "elio.panel.\(id).size" }

    var body: some View {
        content
            .environment(\.panelResized, size != nil)
            .frame(width: size?.width, height: size?.height, alignment: .topLeading)
            .background(GeometryReader { g in
                Color.clear.onAppear { measured = g.size }.onChange(of: g.size) { measured = $1 }
            })
            .overlay { handles }
            .modifier(Dormant(off: dormant))
            .frame(width: base?.width, height: base?.height, alignment: .topLeading)
            .offset(offset)
            // Drag anywhere on the panel; the small minimum distance keeps clicks and buttons working.
            .simultaneousGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in
                    guard resizeStart == nil else { return }
                    let start = dragStart ?? offset
                    dragStart = start
                    offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                }
                .onEnded { _ in
                    guard dragStart != nil else { return }
                    dragStart = nil
                    save()
                })
            .onAppear(perform: restore)
            .onReceive(NotificationCenter.default.publisher(for: .resetDashboardLayout)) { _ in
                withAnimation(.spring(duration: 0.4)) { offset = .zero; size = nil; base = nil }
                UserDefaults.standard.removeObject(forKey: Self.key(id))
                UserDefaults.standard.removeObject(forKey: Self.sizeKey(id))
            }
    }

    // MARK: Resize handles: 4 edges + 4 corners, invisible, with the right cursor.

    /// (x, y): -1 = left/top, 1 = right/bottom, 0 = that axis doesn't change.
    private struct Grip: Hashable { let x: Int; let y: Int }

    private var handles: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, e: CGFloat = 10, c: CGFloat = 22
            ZStack(alignment: .topLeading) {
                // Edges (between the corners), half inside half outside the card.
                grip(Grip(x: 0, y: -1)).frame(width: max(0, w - c), height: e).offset(x: c / 2, y: -e / 2)
                grip(Grip(x: 0, y: 1)).frame(width: max(0, w - c), height: e).offset(x: c / 2, y: h - e / 2)
                grip(Grip(x: -1, y: 0)).frame(width: e, height: max(0, h - c)).offset(x: -e / 2, y: c / 2)
                grip(Grip(x: 1, y: 0)).frame(width: e, height: max(0, h - c)).offset(x: w - e / 2, y: c / 2)
                // Corners, generous: diagonal resizing is what people reach for.
                grip(Grip(x: -1, y: -1)).frame(width: c, height: c).offset(x: -c / 2, y: -c / 2)
                grip(Grip(x: 1, y: -1)).frame(width: c, height: c).offset(x: w - c / 2, y: -c / 2)
                grip(Grip(x: -1, y: 1)).frame(width: c, height: c).offset(x: -c / 2, y: h - c / 2)
                grip(Grip(x: 1, y: 1)).frame(width: c, height: c).offset(x: w - c / 2, y: h - c / 2)
            }
        }
    }

    private func cursor(_ grip: Grip) -> NSCursor {
        let position: NSCursor.FrameResizePosition = switch (grip.x, grip.y) {
        case (-1, -1): .topLeft
        case (1, -1): .topRight
        case (-1, 1): .bottomLeft
        case (1, 1): .bottomRight
        case (0, -1): .top
        case (0, 1): .bottom
        case (-1, 0): .left
        default: .right
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    /// An AppKit grip: it gets the mouse before the card's own scroll views and gestures (SwiftUI drag
    /// handles lost the drag over scrolling content, so some edges and corners didn't respond or stopped).
    private func grip(_ grip: Grip) -> some View {
        ResizeGrip(cursor: cursor(grip), onDrag: { t in resize(grip, by: t) }, onEnd: {
            resizeStart = nil
            save()
        })
    }

    private func resize(_ grip: Grip, by t: CGSize) {
        if resizeStart == nil {
            let current = size ?? measured
            if base == nil { base = measured }   // freeze the layout footprint
            resizeStart = (current, offset)
        }
        guard let start = resizeStart else { return }
        var w = start.size.width, h = start.size.height
        var o = start.offset
        if grip.x == 1 { w = max(Self.minSize.width, start.size.width + t.width) }
        if grip.x == -1 {
            w = max(Self.minSize.width, start.size.width - t.width)
            o.width = start.offset.width + (start.size.width - w)
        }
        if grip.y == 1 { h = max(Self.minSize.height, start.size.height + t.height) }
        if grip.y == -1 {
            h = max(Self.minSize.height, start.size.height - t.height)
            o.height = start.offset.height + (start.size.height - h)
        }
        size = CGSize(width: w, height: h)
        offset = o
    }

    // MARK: Persistence

    private func save() {
        UserDefaults.standard.set([offset.width, offset.height], forKey: Self.key(id))
        if let size, let base {
            UserDefaults.standard.set([size.width, size.height, base.width, base.height], forKey: Self.sizeKey(id))
        }
    }

    private func restore() {
        if let v = UserDefaults.standard.array(forKey: Self.key(id)) as? [Double], v.count == 2 {
            offset = CGSize(width: v[0], height: v[1])
        }
        if let v = UserDefaults.standard.array(forKey: Self.sizeKey(id)) as? [Double], v.count == 4 {
            size = CGSize(width: v[0], height: v[1])
            base = CGSize(width: v[2], height: v[3])
        }
    }
}

/// Invisible resize handle backed by an NSView: its own cursor rect and mouse tracking, so it works over
/// scroll views and never leaves the cursor stuck. Reports the drag as a translation (y grows downwards).
struct ResizeGrip: NSViewRepresentable {
    let cursor: NSCursor
    let onDrag: (CGSize) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> GripView { GripView() }

    func updateNSView(_ view: GripView, context: Context) {
        view.cursor = cursor
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.window?.invalidateCursorRects(for: view)
    }

    final class GripView: NSView {
        var cursor = NSCursor.arrow
        var onDrag: ((CGSize) -> Void)?
        var onEnd: (() -> Void)?
        private var start: NSPoint?

        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let p = event.locationInWindow
            onDrag?(CGSize(width: p.x - start.x, height: start.y - p.y))
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            onEnd?()
        }
    }
}

/// During the briefing, panels start "switched off" and light up when Elio consults their source.
struct Dormant: ViewModifier {
    let off: Bool

    func body(content: Content) -> some View {
        content
            .saturation(off ? 0 : 1)
            .opacity(off ? 0.28 : 1)
            .blur(radius: off ? 1.2 : 0)
            .scaleEffect(off ? 0.98 : 1)
            .animation(.easeOut(duration: 0.6), value: off)
    }
}

/// True inside a panel the user has resized: its own height caps must give way.
extension EnvironmentValues {
    @Entry var panelResized = false
}

extension View {
    /// `maxHeight` that applies only while the panel keeps its natural size.
    func panelMaxHeight(_ h: CGFloat) -> some View { modifier(PanelMaxHeight(h: h)) }
}

private struct PanelMaxHeight: ViewModifier {
    let h: CGFloat
    @Environment(\.panelResized) private var resized
    func body(content: Content) -> some View { content.frame(maxHeight: resized ? .infinity : h) }
}

extension Notification.Name {
    static let resetDashboardLayout = Notification.Name("elio.resetDashboardLayout")
}

/// Markdown rendered with WebKit (tables included), transparent over the dashboard.
struct HTMLView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let page = MarkdownHTML.page(body: MarkdownHTML.render(markdown), title: "", dark: true)
            .replacingOccurrences(of: "background:#0E0E10", with: "background:transparent")
        web.loadHTMLString(page, baseURL: nil)
    }
}
