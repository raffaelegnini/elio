import ElioCore
import SwiftUI
import WebKit

/// Lets the user drag a dashboard panel anywhere (by its grip); the position is remembered.
struct Movable<Content: View>: View {
    let id: String
    @ViewBuilder let content: Content
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var hover = false

    static func key(_ id: String) -> String { "elio.panel.\(id)" }

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent.opacity(hover ? 0.9 : 0.35))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.bg.opacity(hover ? 0.8 : 0)))
                    .contentShape(Rectangle())
                    .onHover { hover = $0 }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { v in
                            let start = dragStart ?? offset
                            dragStart = start
                            offset = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            UserDefaults.standard.set([offset.width, offset.height], forKey: Self.key(id))
                        })
                    .help("Trascina per spostare")
                    .padding(4)
            }
            .offset(offset)
            .onAppear {
                if let v = UserDefaults.standard.array(forKey: Self.key(id)) as? [Double], v.count == 2 {
                    offset = CGSize(width: v[0], height: v[1])
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetDashboardLayout)) { _ in
                withAnimation(.spring(duration: 0.4)) { offset = .zero }
                UserDefaults.standard.removeObject(forKey: Self.key(id))
            }
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
