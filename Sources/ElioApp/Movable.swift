import AppKit
import ElioCore
import SwiftUI
import WebKit

/// A dashboard panel the user can move by dragging it anywhere and resize from its right/bottom
/// edges or corner (no buttons). Position and size are remembered.
struct Movable<Content: View>: View {
    let id: String
    var dormant = false
    @ViewBuilder let content: Content
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var size: CGSize?
    @State private var resizeStart: CGSize?
    @State private var measured: CGSize = .zero

    static func key(_ id: String) -> String { "elio.panel.\(id)" }
    static func sizeKey(_ id: String) -> String { "elio.panel.\(id).size" }

    var body: some View {
        content
            .frame(width: size?.width, height: size?.height)
            .background(GeometryReader { g in Color.clear.onAppear { measured = g.size }.onChange(of: g.size) { measured = $1 } })
            .overlay { edges }
            .modifier(Dormant(off: dormant))
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
                    UserDefaults.standard.set([offset.width, offset.height], forKey: Self.key(id))
                })
            .onAppear {
                if let v = UserDefaults.standard.array(forKey: Self.key(id)) as? [Double], v.count == 2 {
                    offset = CGSize(width: v[0], height: v[1])
                }
                if let v = UserDefaults.standard.array(forKey: Self.sizeKey(id)) as? [Double], v.count == 2 {
                    size = CGSize(width: v[0], height: v[1])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetDashboardLayout)) { _ in
                withAnimation(.spring(duration: 0.4)) { offset = .zero; size = nil }
                UserDefaults.standard.removeObject(forKey: Self.key(id))
                UserDefaults.standard.removeObject(forKey: Self.sizeKey(id))
            }
    }

    /// Invisible resize handles on the right edge, bottom edge and bottom-right corner.
    private var edges: some View {
        ZStack(alignment: .bottomTrailing) {
            HStack { Spacer(); handle(.horizontal).frame(width: 8) }
            VStack { Spacer(); handle(.vertical).frame(height: 8) }
            handle(.both).frame(width: 16, height: 16)
        }
    }

    private enum Axis { case horizontal, vertical, both }

    private func handle(_ axis: Axis) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    switch axis {
                    case .horizontal: NSCursor.resizeLeftRight.push()
                    case .vertical: NSCursor.resizeUpDown.push()
                    case .both: NSCursor.crosshair.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = resizeStart ?? (size ?? measured)
                    resizeStart = start
                    let w = axis == .vertical ? start.width : max(220, start.width + v.translation.width)
                    let h = axis == .horizontal ? start.height : max(120, start.height + v.translation.height)
                    size = CGSize(width: w, height: h)
                }
                .onEnded { _ in
                    resizeStart = nil
                    if let size { UserDefaults.standard.set([size.width, size.height], forKey: Self.sizeKey(id)) }
                })
    }
}

/// During the briefing, panels start "switched off" and light up when Elio consults their source.
struct Dormant: ViewModifier {
    let off: Bool

    func body(content: Content) -> some View {
        content
            .saturation(off ? 0 : 1)
            .brightness(off ? -0.25 : 0)
            .opacity(off ? 0.45 : 1)
            .scaleEffect(off ? 0.985 : 1)
            .overlay {
                if off {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.06))
                        .overlay(alignment: .center) {
                            Image(systemName: "power").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.25))
                        }
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.6), value: off)
    }
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
