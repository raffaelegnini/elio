import AppKit
import ElioCore
import SwiftUI
import WebKit

/// What Elio shows on screen stays there: each card opens in its own window (tables and all)
/// until the user closes it. Same title → the window is updated instead of duplicated.
@MainActor
final class CardWindows: NSObject, NSWindowDelegate {
    static let shared = CardWindows()
    private var windows: [String: NSWindow] = [:]

    func show(title: String, markdown: String) {
        let html = MarkdownHTML.page(body: MarkdownHTML.render(markdown), title: title, dark: true)
        if let existing = windows[title], let web = existing.contentView?.subviews.compactMap({ $0 as? WKWebView }).first {
            web.loadHTMLString(html, baseURL: nil)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Theme.bg)
        window.delegate = self

        let container = NSView()
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSHostingView(rootView: CardHeader(title: title, markdown: markdown))
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(web)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        web.loadHTMLString(html, baseURL: nil)
        cascade(window)
        windows[title] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== w }
    }

    private func cascade(_ w: NSWindow) {
        guard let screen = NSScreen.main?.visibleFrame else { w.center(); return }
        let offset = CGFloat(windows.count % 6) * 28
        w.setFrameOrigin(NSPoint(x: screen.midX - w.frame.width / 2 + offset, y: screen.midY - w.frame.height / 2 - offset))
    }
}

private struct CardHeader: View {
    let title: String
    let markdown: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.accent).frame(width: 3, height: 14)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer()
            Button(copied ? "Copiato ✓" : "Copia") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                copied = true
            }
            .buttonStyle(HUDButton(color: Theme.dim))
            Button("Salva PDF") { savePDF() }.buttonStyle(HUDButton(color: Theme.accent))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.panel)
    }

    private func savePDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".pdf"
        panel.directoryURL = ElioPaths.outputDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = MarkdownHTML.page(body: MarkdownHTML.render(markdown), title: title)
        Task { @MainActor in
            try? await PDFRenderer.render(html: html, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
