import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// The user's projects as a tree discovered by the daemon (dev/DNA/magento/…). Hover a repository
/// for its git state; click to open it in the editor.
struct ProjectsPanel: View {
    let loop: VoiceLoop
    @State private var roots: [ProjectNode] = []
    @State private var expanded: Set<String> = Self.loadExpanded()
    @State private var hovered: String?
    @State private var info: [String: String] = [:]
    @State private var query = ""

    private var top: [ProjectNode] {
        // A single root (~/Desktop/dev) is implied: show its content.
        roots.count == 1 && !roots[0].isRepo ? roots[0].children : roots
    }
    private var total: Int { roots.reduce(0) { $0 + $1.repoCount } }

    var body: some View {
        GlassPanel(title: "PROGETTI", trailing: total > 0 ? "\(total)" : nil) {
            if roots.isEmpty {
                Text("Cerco i progetti…").font(.system(size: 12)).foregroundStyle(Theme.dim)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.dim)
                    TextField("Filtra", text: $query).textFieldStyle(.plain).font(.system(size: 11.5))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered(top)) { node in rows(node, depth: 0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .panelMaxHeight(340)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func filtered(_ nodes: [ProjectNode]) -> [ProjectNode] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nodes }
        return nodes.compactMap { n in
            if n.isRepo { return n.name.lowercased().contains(q) || (n.stack ?? "").contains(q) ? n : nil }
            var g = n
            g.children = n.name.lowercased().contains(q) ? n.children : filtered(n.children)
            return g.children.isEmpty ? nil : g
        }
    }

    private func isOpen(_ n: ProjectNode) -> Bool { !query.isEmpty || expanded.contains(n.path) }

    private func rows(_ node: ProjectNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 1) {
            row(node, depth: depth)
            if !node.isRepo, isOpen(node) {
                ForEach(node.children) { rows($0, depth: depth + 1) }
            }
        })
    }

    private func row(_ node: ProjectNode, depth: Int) -> some View {
        let isHover = hovered == node.path
        return HStack(spacing: 6) {
            if node.isRepo {
                Circle().fill(StackBadge.color(node.stack)).frame(width: 6, height: 6).padding(.leading, 3)
            } else {
                Image(systemName: isOpen(node) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.dim).frame(width: 12)
                Image(systemName: isOpen(node) ? "folder.fill" : "folder").font(.system(size: 10.5)).foregroundStyle(Theme.accent)
            }
            Text(node.name)
                .font(.system(size: 12, weight: node.isRepo ? .regular : .semibold))
                .foregroundStyle(node.isRepo ? Theme.text.opacity(0.9) : Theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if node.isRepo, let s = node.stack {
                StackBadge(stack: s)
            } else if !node.isRepo {
                Text("\(node.repoCount)").font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 3).padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHover ? Theme.accent.opacity(0.12) : .clear))
        .overlay(alignment: .leading) {
            if isHover { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2).padding(.vertical, 3) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? node.path : (hovered == node.path ? nil : hovered) }
            if inside, node.isRepo, info[node.path] == nil { Task { await loadInfo(node.path) } }
        }
        .popover(isPresented: Binding(get: { isHover && node.isRepo }, set: { _ in }), arrowEdge: .trailing) {
            RepoCard(node: node, info: info[node.path])
        }
        .onTapGesture {
            if node.isRepo { open(node.path) } else { toggle(node.path) }
        }
    }

    private func toggle(_ path: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        }
        UserDefaults.standard.set(Array(expanded), forKey: "elio.projects.expanded")
    }

    static func loadExpanded() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "elio.projects.expanded") ?? [])
    }

    /// Opens in VS Code / Cursor if installed, otherwise in Finder.
    private func open(_ path: String) {
        let url = URL(fileURLWithPath: path)
        for id in ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.jetbrains.PhpStorm"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    private func load() async {
        let (json, err) = await loop.callTool("project_tree")
        guard !err, let nodes = [ProjectNode].fromJSON(json) else { return }
        roots = nodes
        // First run: open the first level so the structure is visible.
        if expanded.isEmpty { expanded = Set(top.filter { !$0.isRepo }.prefix(2).map(\.path)) }
    }

    private func loadInfo(_ path: String) async {
        info[path] = "…"
        let (text, err) = await loop.callTool("project_info", ["path": path])
        info[path] = err ? "Stato git non disponibile" : text
    }
}

private struct RepoCard: View {
    let node: ProjectNode
    let info: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(node.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                if let s = node.stack { StackBadge(stack: s) }
            }
            Text(node.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.dim)
            Divider().overlay(Theme.line)
            Text(info ?? "…").font(.system(size: 11.5)).foregroundStyle(Theme.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Text("Clic per aprire nell'editor").font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Theme.bg)
    }
}

struct StackBadge: View {
    let stack: String

    static func color(_ stack: String?) -> Color {
        switch stack {
        case "magento": Color(hex: "#F26322")
        case "hyva": Color(hex: "#7B5CFF")
        case "laravel": Color(hex: "#FF2D20")
        case "shopify": Color(hex: "#95BF47")
        case "flutter": Color(hex: "#47C5FB")
        case "swift": Color(hex: "#F05138")
        case "next", "react", "react-native": Color(hex: "#61DAFB")
        case "vue": Color(hex: "#42B883")
        case "node": Color(hex: "#8CC84B")
        case "python": Color(hex: "#FFD43B")
        case "php": Color(hex: "#777BB4")
        default: Color(hex: "#9E9A8E")
        }
    }

    var body: some View {
        Text(stack.uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.6)
            .foregroundStyle(Self.color(stack))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Self.color(stack).opacity(0.14)))
    }
}
