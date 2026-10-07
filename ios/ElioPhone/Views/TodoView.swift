import SwiftUI

struct TodoView: View {
    @Environment(AppModel.self) private var model
    @State private var newItem = ""

    var body: some View {
        @Bindable var todos = model.todos
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(todos.todayDone), total: Double(max(1, todos.todayTotal)))
                    .tint(Theme.accent)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                Picker("Lista", selection: $todos.list) {
                    ForEach(TodoModel.List.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                List {
                    if let error = todos.error, todos.board == nil {
                        Text(error).foregroundStyle(Theme.text2).frame(maxWidth: .infinity).listRowBackground(Color.clear)
                    }
                    if todos.list == .today, let overdue = todos.board?.overdue, !overdue.isEmpty {
                        Section {
                            ForEach(overdue) { TodoRow(item: $0, late: true) }
                        } header: {
                            HStack {
                                Text("Rimaste indietro (\(overdue.count))").foregroundStyle(Theme.warn)
                                Spacer()
                                Button("Porta a oggi") { todos.act("carry") }.font(.footnote.weight(.semibold))
                            }
                        }
                    }
                    Section {
                        let items = todos.items(todos.list)
                        ForEach(items) { TodoRow(item: $0, late: false) }
                        if items.isEmpty, todos.board != nil {
                            Text(todos.list == .today ? "Niente in lista. Dimmi cosa vuoi fare oggi." : "Niente qui.")
                                .foregroundStyle(Theme.text3).frame(maxWidth: .infinity).padding(.vertical, 20)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        if todos.list == .today, !(todos.board?.overdue.isEmpty ?? true) { Text("Oggi") }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await todos.load() }
                HStack(spacing: 8) {
                    TextField("Aggiungi (!importante @domani 18:30)", text: $newItem)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    Button(action: add) {
                        Image(systemName: "plus").font(.body.weight(.bold)).foregroundStyle(Theme.accentInk)
                            .frame(width: 44, height: 44).background(Circle().fill(Theme.accent))
                    }
                    .accessibilityLabel("Aggiungi")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .background(Theme.bg)
            .navigationTitle("To do")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if todos.todayTotal > 0 {
                        Text("\(todos.todayDone)/\(todos.todayTotal)").font(.footnote.monospaced().weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            .task { await todos.load() }
        }
    }

    private func add() {
        model.todos.add(newItem)
        newItem = ""
    }
}

struct TodoRow: View {
    @Environment(AppModel.self) private var model
    let item: TodoItem
    let late: Bool

    var body: some View {
        let todos = model.todos
        let toToday = late || todos.list != .today
        HStack(alignment: .top, spacing: 12) {
            Button {
                Haptics.tick()
                todos.act("toggle", id: item.id)
            } label: {
                ZStack {
                    Circle().strokeBorder(item.important ? Theme.accent : Theme.text3, lineWidth: 1.6)
                        .opacity(item.done ? 0 : 1)
                    if item.done {
                        Circle().fill(Theme.accent)
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.accentInk)
                    }
                }
                .frame(width: 24, height: 24)
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Da fare" : "Fatto")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .fontWeight(item.important && !item.done ? .semibold : .regular)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Theme.text3 : Theme.text)
                if !meta.isEmpty { Text(meta).font(.footnote).foregroundStyle(Theme.text2) }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Menu {
                Button { todos.act("important", id: item.id) } label: { Label(item.important ? "Normale" : "Importante", systemImage: "star") }
                Button { todos.act("focus", id: item.id) } label: { Label(item.isFocus ? "Togli focus" : "Ci lavoro ora", systemImage: "target") }
                Button { todos.act(toToday ? "today" : "tomorrow", id: item.id) } label: { Label(toToday ? "Oggi" : "Domani", systemImage: "arrow.right") }
                Button(role: .destructive) { todos.act("remove", id: item.id) } label: { Label("Elimina", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.text3).frame(width: 36, height: 32)
            }
            .accessibilityLabel("Altre azioni")
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Color.white.opacity(0.08))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { todos.act("remove", id: item.id) } label: { Label("Elimina", systemImage: "trash") }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if late, let d = item.day, d.count >= 10 {
            parts.append("dal \(d.dropFirst(8).prefix(2))/\(d.dropFirst(5).prefix(2))")
        }
        if let t = item.time { parts.append("alle \(t)") }
        if let e = item.estimate, e > 0 { parts.append("circa \(e) min") }
        if item.isFocus { parts.append("ci stai lavorando") }
        if let n = item.notes, !n.isEmpty { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}
