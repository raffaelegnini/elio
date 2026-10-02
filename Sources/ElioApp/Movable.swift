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
            let w = g.size.width, h = g.size.height, e: CGFloat = 6, c: CGFloat = 14
            ZStack(alignment: .topLeading) {
                // Edges (between the corners).
                handle(Grip(x: 0, y: -1)).frame(width: max(0, w - 2 * c), height: e).offset(x: c, y: -e / 2)
                handle(Grip(x: 0, y: 1)).frame(width: max(0, w - 2 * c), height: e).offset(x: c, y: h - e / 2)
                handle(Grip(x: -1, y: 0)).frame(width: e, height: max(0, h - 2 * c)).offset(x: -e / 2, y: c)
                handle(Grip(x: 1, y: 0)).frame(width: e, height: max(0, h - 2 * c)).offset(x: w - e / 2, y: c)
                // Corners.
                handle(Grip(x: -1, y: -1)).frame(width: c, height: c).offset(x: -c / 2, y: -c / 2)
                handle(Grip(x: 1, y: -1)).frame(width: c, height: c).offset(x: w - c / 2, y: -c / 2)
                handle(Grip(x: -1, y: 1)).frame(width: c, height: c).offset(x: -c / 2, y: h - c / 2)
                handle(Grip(x: 1, y: 1)).frame(width: c, height: c).offset(x: w - c / 2, y: h - c / 2)
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

    private func handle(_ grip: Grip) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in if inside { cursor(grip).push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if resizeStart == nil {
                        let current = size ?? measured
                        if base == nil { base = measured }   // freeze the layout footprint
                        resizeStart = (current, offset)
                    }
                    guard let start = resizeStart else { return }
                    var w = start.size.width, h = start.size.height
                    var o = start.offset
                    if grip.x == 1 { w = max(Self.minSize.width, start.size.width + v.translation.width) }
                    if grip.x == -1 {
                        w = max(Self.minSize.width, start.size.width - v.translation.width)
                        o.width = start.offset.width + (start.size.width - w)
                    }
                    if grip.y == 1 { h = max(Self.minSize.height, start.size.height + v.translation.height) }
                    if grip.y == -1 {
                        h = max(Self.minSize.height, start.size.height - v.translation.height)
                        o.height = start.offset.height + (start.size.height - h)
                    }
                    size = CGSize(width: w, height: h)
                    offset = o
                }
                .onEnded { _ in
                    resizeStart = nil
                    save()
                })
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
