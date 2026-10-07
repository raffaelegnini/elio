import SwiftUI

/// The conversation: workflow status on top, then messages, events and the cards that need an answer.
struct FeedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !model.tasks.isEmpty { TasksCard(tasks: Array(model.tasks.suffix(4).reversed())) }
                    if model.feed.isEmpty && model.tasks.isEmpty {
                        Text("Chiedimi qualcosa, a voce o per iscritto.")
                            .font(.subheadline).foregroundStyle(Theme.text3)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.feed) { item in
                        FeedRow(item: item).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04)], startPoint: .top, endPoint: .bottom))
            .onChange(of: model.feed.last?.text) { withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: model.feed.count) { withAnimation { proxy.scrollTo("bottom") } }
            .onAppear { proxy.scrollTo("bottom") }
        }
    }
}

struct FeedRow: View {
    @Environment(AppModel.self) private var model
    let item: FeedItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(item.text)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20).fill(Theme.bg3))
                    .textSelection(.enabled)
            }
        case .elio:
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .foregroundStyle(item.error ? Theme.danger : Theme.text)
                    .textSelection(.enabled)
                if !item.meta.isEmpty {
                    Text(item.meta).font(.caption2.monospaced()).foregroundStyle(Theme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .event, .alarm:
            let alarm = item.kind == .alarm
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: alarm ? "exclamationmark.triangle" : "bell")
                    .font(.footnote)
                    .foregroundStyle(alarm ? Theme.danger : Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(alarm ? Theme.dangerSoft : Theme.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(alarm ? "Avviso urgente" : "Avviso").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text2)
                    Text(item.text).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.bg2))
        case .confirm(let req):
            ConfirmCard(req: req)
        case .question(let q):
            QuestionCard(q: q)
        }
    }
}

struct ConfirmCard: View {
    @Environment(AppModel.self) private var model
    let req: ConfirmRequest

    var body: some View {
        let danger = req.isDangerous
        VStack(alignment: .leading, spacing: 8) {
            Label(danger ? "Conferma esplicita" : "Conferma", systemImage: danger ? "exclamationmark.triangle" : "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(danger ? Theme.danger : Theme.accent)
            Text(req.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
            if let d = req.detail, !d.isEmpty {
                ScrollView {
                    Text(d).font(.caption.monospaced()).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.3)))
            }
            HStack(spacing: 10) {
                Button { model.answerConfirm(req.id, approved: false) } label: { Text("Annulla").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: .neutral, small: false))
                Button { model.answerConfirm(req.id, approved: true) } label: { Text(danger ? "Confermo" : "Procedi").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(kind: danger ? .danger : .go, small: false))
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(danger ? Theme.dangerSoft : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(danger ? Theme.danger.opacity(0.35) : .clear))
    }
}

struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    let q: QuestionRequest
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Domanda", systemImage: "bubble.left").foregroundStyle(Theme.warn)
                if let from = q.from, !from.isEmpty { Text("da \(from)").foregroundStyle(Theme.text2).fontWeight(.medium) }
            }
            .font(.footnote.weight(.semibold))
            Text(q.question).font(.body.weight(.semibold)).foregroundStyle(Theme.text).padding(.bottom, 4)
            HStack(spacing: 10) {
                TextField("La tua risposta", text: $answer, axis: .vertical)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit(submit)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(Theme.accentInk)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.accent))
                }
                .accessibilityLabel("Invia risposta")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.bg2))
    }

    private func submit() { model.answerQuestion(q.id, text: answer) }
}

struct TasksCard: View {
    let tasks: [TaskInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Workflow", systemImage: "square.stack.3d.up").font(.footnote.weight(.semibold)).foregroundStyle(Theme.text2)
            ForEach(tasks) { t in
                HStack(spacing: 10) {
                    Circle().fill(Theme.status(t.status)).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title + (t.project.map { " · \($0)" } ?? "")).font(.subheadline).foregroundStyle(Theme.text)
                        let step = t.status == "running" ? (t.steps?.last ?? "") : String((t.summary ?? t.status).prefix(120))
                        if !step.isEmpty {
                            Text(step).font(.caption).foregroundStyle(Theme.text2).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.bg2))
    }
}
