import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files attached to the next typed message: a paperclip that opens a file picker, files dropped on the input
/// bar, and chips to remove them. Shared by the dashboard and the HUD.
@MainActor
@Observable
final class PendingAttachments {
    var files: [URL] = []

    func add(_ urls: [URL]) {
        for u in urls where !files.contains(u) { files.append(u) }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Scegli foto o file da mandare a \(Brand.shared.name)"
        NSApp.activate()
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Hands the files over and empties the list.
    func take() -> [URL] {
        defer { files = [] }
        return files
    }

    /// Files dragged onto the input bar.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for p in accepted {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.add([url]) }
            }
        }
        return !accepted.isEmpty
    }
}

struct AttachButton: View {
    let pending: PendingAttachments

    var body: some View {
        Button { pending.pick() } label: {
            Image(systemName: "paperclip").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(pending.files.isEmpty ? Theme.dim : Theme.accent)
        }
        .buttonStyle(.plain)
        .help("Allega foto o file (o trascinali qui)")
    }
}

struct AttachmentChips: View {
    let pending: PendingAttachments

    var body: some View {
        if !pending.files.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(pending.files, id: \.self) { url in
                        HStack(spacing: 5) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 14, height: 14)
                            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).foregroundStyle(Theme.text)
                            Button { pending.files.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}
