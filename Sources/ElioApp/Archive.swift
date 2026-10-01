import ElioCore
import ElioVoice
import SwiftUI

/// Everything that happened, stored locally on the Mac: conversations by day, operations
/// (tools used), agents' work with their full live log, reminders and long-term memory.
struct ArchiveView: View {
    let loop: VoiceLoop

    enum Section: String, CaseIterable, Identifiable {
        case chats = "Conversazioni", operations = "Operazioni", agents = "Agenti", reminders = "Promemoria", memory = "Memoria"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .chats: "bubble.left.and.bubble.right"
            case .operations: "bolt.horizontal"
            case .agents: "cpu"
            case .reminders: "bell"
            case .memory: "brain"
            }
        }
    }

    @State private var section: Section = .chats
    @State private var days: [Memory.DayCount] = []
    @State private var day: String?
    @State private var search = ""
    @State private var messages: [Memory.ArchivedMessage] = []
    @State private var operations: [Memory.ArchivedToolCall] = []
    @State private var tasks: [TaskInfo] = []
    @State private var selectedTask: String?
    @State private var taskLog: [TaskLogEntry] = []
    @State private var reminders: [Memory.ArchivedReminder] = []
    @State private var facts: [FactRow] = []

    struct FactRow: Codable, Identifiable { let id: Int; let text: String; let category: String; let created: Date }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Rectangle().fill(Theme.line).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task { await loadDays(); await load() }
        .onChange(of: section) { Task { await load() } }
        .onChange(of: day) { Task { await load() } }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Brand.shared.dotted).font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(4)
                .foregroundStyle(Theme.text)
            Text("ARCHIVIO").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim).padding(.bottom, 14)
            ForEach(Section.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 10) { Image(systemName: s.icon).frame(width: 18); Text(s.rawValue); Spacer() }
                        .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                        .foregroundStyle(section == s ? Color.black : Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(section == s ? Theme.accent : .clear))
                }
                .buttonStyle(.plain)
            }
            if section == .chats || section == .operations {
                Text("GIORNI").font(Theme.mono).tracking(2).foregroundStyle(Theme.dim).padding(.top, 18).padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(days, id: \.day) { d in
                            Button { day = d.day } label: {
                                HStack {
                                    Text(Self.pretty(d.day)).lineLimit(1)
                                    Spacer()
                                    Text("\(section == .chats ? d.messages : d.tools)").foregroundStyle(Theme.dim)
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(day == d.day ? Theme.accent : Theme.text)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(day == d.day ? Theme.accent.opacity(0.12) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
            Text("Tutto resta sul Mac:\n~/Library/Application Support/Elio").font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
        .padding(18)
        .background(Theme.panel)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .chats: chats
        case .operations: operationsView
        case .agents: agents
        case .reminders: remindersView
        case .memory: memoryView
        }
    }

    private var chats: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Cerca in tutte le conversazioni…", text: $search)
                    .textFieldStyle(.plain).foregroundStyle(Theme.text)
                    .onSubmit { Task { await load() } }
            }
            .padding(12).background(Theme.panel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty { empty("Nessuna conversazione") }
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(m.role == "user" ? "TU" : Brand.shared.name.uppercased())
                                    .font(Theme.mono).tracking(1.5).foregroundStyle(m.role == "user" ? Theme.dim : Theme.accent)
                                Text(m.ts, format: .dateTime.day().month().hour().minute()).font(Theme.mono).foregroundStyle(Theme.dim.opacity(0.7))
                                if let r = m.route { Text(r).font(Theme.mono).foregroundStyle(Theme.dim.opacity(0.6)) }
                            }
                            Text(m.text).font(.system(size: 13)).foregroundStyle(m.role == "user" ? Theme.dim : Theme.text)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var operationsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if operations.isEmpty { empty("Nessuna operazione in questo giorno") }
                ForEach(Array(operations.enumerated()), id: \.offset) { _, o in
                    HStack(spacing: 10) {
                        Text(o.ts, format: .dateTime.hour().minute().second()).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.dim).frame(width: 70, alignment: .leading)
                        Image(systemName: Capability.of(tool: o.name).icon).foregroundStyle(Theme.accent).frame(width: 18)
                        Text(Capability.describe(tool: o.name)).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(o.ms) ms").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.dim)
                        Image(systemName: o.ok ? "checkmark" : "exclamationmark.triangle").foregroundStyle(o.ok ? .green : .orange)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
    }

    private var agents: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tasks.isEmpty { empty("Nessun lavoro degli agenti") }
                    ForEach(tasks) { t in
                        Button { selectedTask = t.id; Task { await loadLog(t.id) } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { StatusDot(status: t.status); Text(t.title).lineLimit(1) }
                                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                                Text("\(t.project ?? "") · \((t.endedAt ?? t.startedAt).formatted(.dateTime.day().month().hour().minute()))")
                                    .font(Theme.mono).foregroundStyle(Theme.dim)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selectedTask == t.id ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .frame(width: 300)
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if let t = tasks.first(where: { $0.id == selectedTask }), let summary = t.summary {
                        Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    }
                    if selectedTask != nil && taskLog.isEmpty { empty("Nessun dettaglio registrato per questo lavoro") }
                    ForEach(taskLog) { LogLine(entry: $0) }
                }
                .padding(18)
            }
        }
    }

    private var remindersView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if reminders.isEmpty { empty("Nessun promemoria") }
                ForEach(reminders, id: \.id) { r in
                    HStack(spacing: 10) {
                        Image(systemName: r.done ? "checkmark.circle.fill" : "bell").foregroundStyle(r.done ? .green : Theme.accent)
                        Text(r.text).font(.system(size: 13)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(r.at, format: .dateTime.day().month().hour().minute()).font(Theme.mono).foregroundStyle(Theme.dim)
                    }
                }
            }
            .padding(20)
        }
    }

    private var memoryView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if facts.isEmpty { empty("La memoria a lungo termine è vuota") }
                ForEach(facts) { f in
                    HStack(alignment: .top, spacing: 10) {
                        Text(f.category.uppercased()).font(Theme.mono).foregroundStyle(Theme.accent).frame(width: 90, alignment: .leading)
                        Text(f.text).font(.system(size: 13)).foregroundStyle(Theme.text).textSelection(.enabled)
                        Spacer()
                        Button {
                            Task { _ = await loop.callTool("forget", ["id": f.id]); await load() }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Dimentica")
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.dim).padding(.vertical, 30)
    }

    // MARK: - Data

    private func call<T: Decodable>(_ args: [String: Any], as: T.Type) async -> T? {
        let (text, err) = await loop.callTool("history", args)
        return err ? nil : T.fromJSON(text)
    }

    private func loadDays() async {
        days = await call(["section": "days"], as: [Memory.DayCount].self) ?? []
        if day == nil { day = days.first?.day }
    }

    private func load() async {
        switch section {
        case .chats:
            var args: [String: Any] = ["section": "messages"]
            if search.isEmpty, let day { args["day"] = day }
            if !search.isEmpty { args["search"] = search }
            messages = await call(args, as: [Memory.ArchivedMessage].self) ?? []
        case .operations:
            operations = await call(["section": "operations", "day": day ?? Routines.dayKey(Date())], as: [Memory.ArchivedToolCall].self) ?? []
        case .agents:
            tasks = await call(["section": "tasks"], as: [TaskInfo].self) ?? []
        case .reminders:
            reminders = await call(["section": "reminders"], as: [Memory.ArchivedReminder].self) ?? []
        case .memory:
            facts = await call(["section": "memory"], as: [FactRow].self) ?? []
        }
    }

    private func loadLog(_ id: String) async {
        taskLog = await call(["section": "task_log", "task_id": id], as: [TaskLogEntry].self) ?? []
    }

    static func pretty(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return "Oggi" }
        if Calendar.current.isDateInYesterday(d) { return "Ieri" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "it_IT")))
    }
}
