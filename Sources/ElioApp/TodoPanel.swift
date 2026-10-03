import ElioCore
import ElioVoice
import SwiftUI

/// The to-do list in the dashboard: today first (focus on top, then what's left, then what's done), what's left
/// over from past days, tomorrow and "prima o poi". One tap to tick, hover for the quick actions, a field
/// that understands "!importante @domani 18:30", and a button to plan the day with Elio.
struct TodoPanel: View {
    let loop: VoiceLoop
    @State private var input = ""
    @State private var tab: Tab = .today
    @State private var showDone = false
    @Environment(\.liveLayers) private var liveLayers

    enum Tab: String, CaseIterable { case today = "Oggi", tomorrow = "Domani", someday = "Prima o poi" }

    private var board: TodoBoard? { loop.todoBoard }

    private var items: [TodoItem] {
        guard let b = board else { return [] }
        switch tab {
        case .today: return b.today
        case .tomorrow: return b.tomorrow
        case .someday: return b.someday
        }
    }

    private var progress: String? {
        guard let today = board?.today, !today.isEmpty else { return nil }
        return "\(today.filter(\.done).count)/\(today.count)"
    }

    var body: some View {
        GlassPanel(title: "TO DO", trailing: progress) {
            VStack(alignment: .leading, spacing: 10) {
                if let today = board?.today, !today.isEmpty, tab == .today { progressBar(today) }
                tabs
                scrollable {
                    VStack(alignment: .leading, spacing: 2) {
                        if tab == .today, let overdue = board?.overdue, !overdue.isEmpty { overdueSection(overdue) }
                        let open = items.filter { !$0.done }
                        let done = items.filter(\.done)
                        if let focus = open.first(where: \.focus) {
                            Text("IN CORSO").font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1.5)
                                .foregroundStyle(Theme.accent).padding(.top, 2)
                            TodoRow(item: focus, loop: loop, act: act)
                            Divider().overlay(Theme.line).padding(.vertical, 4)
                        }
                        ForEach(open.filter { !$0.focus }) { TodoRow(item: $0, loop: loop, act: act) }
                        if open.isEmpty && done.isEmpty {
                            Text(emptyText).font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.vertical, 4)
                        }
                        if !done.isEmpty {
                            Button { withAnimation(.easeOut(duration: 0.2)) { showDone.toggle() } } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showDone ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                                    Text("FATTE (\(done.count))").font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1.5)
                                }
                                .foregroundStyle(Theme.dim)
                            }
                            .buttonStyle(.plain).padding(.top, 6)
                            if showDone { ForEach(done) { TodoRow(item: $0, loop: loop, act: act) } }
                        }
                    }
                }
                addField
                footer
            }
        }
        .panelMaxHeight(360)
        .task { if liveLayers { await reload() } }
    }

    /// Snapshots (ImageRenderer) don't draw scroll view content.
    @ViewBuilder private func scrollable(@ViewBuilder _ content: () -> some View) -> some View {
        if liveLayers { ScrollView { content() }.scrollIndicators(.never) } else { content() }
    }

    private var emptyText: String {
        switch tab {
        case .today: "Niente in lista. Dimmi cosa vuoi fare oggi, o scrivilo qui sotto."
        case .tomorrow: "Niente per domani."
        case .someday: "Le cose da fare prima o poi finiscono qui."
        }
    }

    private func progressBar(_ today: [TodoItem]) -> some View {
        let done = Double(today.filter(\.done).count) / Double(max(today.count, 1))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * done)
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.3), value: done)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                let count = t == .today ? board?.today.filter { !$0.done }.count : t == .tomorrow ? board?.tomorrow.count : board?.someday.count
                Button { tab = t } label: {
                    Text("\(t.rawValue)\(count.map { $0 > 0 ? " \($0)" : "" } ?? "")")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(tab == t ? Theme.accent.opacity(0.18) : .clear))
                        .foregroundStyle(tab == t ? Theme.accent : Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func overdueSection(_ overdue: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("RIMASTE INDIETRO (\(overdue.count))").font(.system(size: 8.5, weight: .bold, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(Color(hex: "#FF9F43"))
                Spacer()
                Button("Porta a oggi") { act("carry", nil) }.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            ForEach(overdue) { TodoRow(item: $0, loop: loop, act: act, overdue: true) }
            Divider().overlay(Theme.line).padding(.vertical, 4)
        }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
            TextField("Aggiungi…  (!importante  @domani  18:30)", text: $input)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.text)
                .onSubmit {
                    let text = input.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    let suffix = tab == .tomorrow && !text.contains("@") ? " @domani" : tab == .someday && !text.contains("@") ? " @prima o poi" : ""
                    input = ""
                    act("add", nil, text: text + suffix)
                }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private var footer: some View {
        HStack {
            if tab == .today, let left = board?.today.filter({ !$0.done }), !left.isEmpty {
                let minutes = left.reduce(0) { $0 + $1.estimate }
                if minutes > 0 {
                    Text("~\(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60 > 0 ? "\(minutes % 60) min" : "")" : "\(minutes) min") stimati")
                        .font(Theme.mono).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            Button { loop.submit(text: "Pianifichiamo la giornata: guarda la mia to-do list e l'agenda e aiutami a organizzarla.") } label: {
                Label("Pianifica con \(Brand.shared.name)", systemImage: "sparkles").font(.system(size: 10.5, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
        }
    }

    private func act(_ action: String, _ id: Int?, text: String? = nil) {
        var args: [String: Any] = ["action": action]
        if let id { args["id"] = id }
        if let text { args["text"] = text }
        Task {
            let (json, err) = await loop.callTool("todo_board", args)
            if !err, let b = TodoBoard.fromJSON(json) { loop.todoBoard = b }
        }
    }

    private func reload() async {
        let (json, err) = await loop.callTool("todo_board")
        if !err, let b = TodoBoard.fromJSON(json) { loop.todoBoard = b }
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let loop: VoiceLoop
    let act: (String, Int?, String?) -> Void
    var overdue = false
    @State private var hover = false

    init(item: TodoItem, loop: VoiceLoop, act: @escaping (String, Int?, String?) -> Void, overdue: Bool = false) {
        self.item = item; self.loop = loop; self.act = act; self.overdue = overdue
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { act("toggle", item.id, nil) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? Theme.accent.opacity(0.7) : item.priority > 0 ? Theme.accent : Theme.dim)
            }
            .buttonStyle(.plain)
            .help(item.done ? "Rimetti da fare" : "Fatto")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12, weight: item.priority > 0 && !item.done ? .semibold : .regular))
                    .foregroundStyle(item.done ? Theme.dim : Theme.text)
                    .strikethrough(item.done, color: Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                let meta = metadata
                if !meta.isEmpty {
                    Text(meta).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(overdue ? Color(hex: "#FF9F43") : Theme.dim)
                }
            }
            Spacer(minLength: 0)
            if hover, !item.done { actions }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.white.opacity(0.05) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(item.done ? "Rimetti da fare" : "Fatto") { act("toggle", item.id, nil) }
            Button(item.priority > 0 ? "Non importante" : "Importante") { act("important", item.id, nil) }
            Button(item.focus ? "Togli dal focus" : "Ci lavoro ora") { act("focus", item.id, nil) }
            Divider()
            Button("Sposta a oggi") { act("today", item.id, nil) }
            Button("Sposta a domani") { act("tomorrow", item.id, nil) }
            Button("Prima o poi") { act("someday", item.id, nil) }
            Button("Su") { act("up", item.id, nil) }
            Button("Giù") { act("down", item.id, nil) }
            Divider()
            Button("Aiutami con questa") {
                loop.submit(text: "Aiutami con questa voce della mia to-do list: \(item.text)\(item.notes.isEmpty ? "" : " (\(item.notes))"). Dimmi da dove partire.")
            }
            Button("Delegala a un agente") {
                loop.submit(text: "Delega a un agente questa voce della mia to-do list, se si può fare in autonomia: \(item.text)\(item.notes.isEmpty ? "" : " (\(item.notes))"). Spuntala quando ha finito.")
            }
            Divider()
            Button("Elimina", role: .destructive) { act("remove", item.id, nil) }
        }
    }

    private var metadata: String {
        var parts: [String] = []
        if overdue, let day = item.day { parts.append("dal \(day.suffix(5).split(separator: "-").reversed().joined(separator: "/"))") }
        if let t = item.time { parts.append("⏰ \(t)") }
        if item.estimate > 0 { parts.append("~\(item.estimate) min") }
        if item.parent != nil { parts.append("↻") }
        if !item.notes.isEmpty { parts.append(item.notes) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 6) {
            icon(item.priority > 0 ? "star.fill" : "star", "Importante") { act("important", item.id, nil) }
            icon(item.focus ? "scope" : "target", "Ci lavoro ora") { act("focus", item.id, nil) }
            icon("arrow.turn.down.right", overdue ? "Porta a oggi" : "Domani") { act(overdue ? "today" : "tomorrow", item.id, nil) }
            icon("trash", "Elimina") { act("remove", item.id, nil) }
        }
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 10)) }
            .buttonStyle(.plain).foregroundStyle(Theme.dim).help(help)
    }
}
