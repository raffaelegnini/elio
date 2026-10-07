import SwiftUI
import WebKit

struct WorkflowView: View {
    @Environment(AppModel.self) private var model

    private static let statusText = ["running": "in corso", "done": "completato", "failed": "fallito", "cancelled": "fermato"]

    var body: some View {
        let wf = model.workflows
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Modalità", selection: Binding(get: { wf.mode }, set: { wf.setMode($0) })) {
                        Label("Parlante", systemImage: "bubble.left").tag("talking")
                        Label("Silenziosa", systemImage: "moon").tag("silent")
                    }
                    .pickerStyle(.segmented)
                    Text(wf.mode == "silent"
                         ? "Elio sta zitto mentre gli agenti lavorano: ti cerca solo per domande, problemi e alla fine."
                         : "Elio ti racconta i progressi e le decisioni che prende al posto tuo.")
                        .font(.footnote).foregroundStyle(Theme.text2)
                        .padding(.bottom, 4)
                    if let error = wf.error {
                        Text(error).font(.subheadline).foregroundStyle(Theme.text2).frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else if wf.loaded && wf.items.isEmpty {
                        Text("Nessun workflow ancora. Chiedi a Elio di mettere su una squadra.")
                            .font(.subheadline).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(wf.items) { WorkflowCard(item: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Theme.bg)
            .navigationTitle("Workflow")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SettingsButton() } }
            .refreshable { await wf.load() }
            .task { await wf.load() }
        }
    }

    struct WorkflowCard: View {
        @Environment(AppModel.self) private var model
        let item: WorkflowItem

        var body: some View {
            let wf = item.workflow
            let workers = item.agents.filter { $0.kind != "lead" }
            let finished = workers.filter { ["done", "failed", "cancelled"].contains($0.status) }.count
            let pct = wf.status == "running" ? Double(finished) / Double(max(1, workers.count)) : 1
            let cost = item.agents.reduce(0) { $0 + ($1.costUSD ?? 0) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(wf.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text((WorkflowView.statusText[wf.status] ?? wf.status) + ((item.pending ?? 0) > 0 ? " · attende te" : ""))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .foregroundStyle(pillColor(wf.status))
                        .background(Capsule().fill(pillColor(wf.status).opacity(0.14)))
                }
                ProgressView(value: pct).tint(Theme.accent)
                ForEach(item.agents) { a in AgentRow(agent: a) }
                HStack {
                    Text("\(wf.startedAt.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "it_IT"))) } ?? "") · $\(String(format: "%.2f", cost))")
                        .font(.caption.monospaced()).foregroundStyle(Theme.text3)
                    Spacer()
                    Button { model.reportId = wf.id } label: {
                        HStack(spacing: 2) { Text("Report"); Image(systemName: "chevron.right") }
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.bg2))
        }

        private func pillColor(_ s: String) -> Color {
            switch s { case "done": Theme.ok; case "failed": Theme.danger; case "cancelled": Theme.text2; default: Theme.accent }
        }
    }

    struct AgentRow: View {
        @Environment(AppModel.self) private var model
        let agent: TaskInfo

        var body: some View {
            let active = agent.isActive
            HStack(spacing: 8) {
                Circle().fill(Theme.status(agent.status)).frame(width: 8, height: 8)
                Text(agent.member ?? "agente").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.subheadline).foregroundStyle(Theme.text2).lineLimit(1)
                Spacer(minLength: 0)
                if active {
                    let paused = agent.status == "paused"
                    Button { model.workflows.control(agent.id, paused ? "resume" : "pause") } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill").font(.caption)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.fill))
                    }
                    .accessibilityLabel(paused ? "Riprendi" : "Pausa")
                    Button { model.workflows.control(agent.id, "stop") } label: {
                        Image(systemName: "stop.fill").font(.caption)
                            .frame(width: 36, height: 36).background(Circle().fill(Theme.fill))
                    }
                    .accessibilityLabel("Ferma")
                }
            }
            .foregroundStyle(Theme.text)
            .frame(minHeight: 32)
        }

        private var detail: String {
            if agent.isActive { return agent.lastMessage ?? agent.steps?.last ?? agent.role ?? "" }
            return (agent.summary ?? agent.status).components(separatedBy: "\n").first ?? ""
        }
    }
}

/// The Mac's report page (report.html) in a web view, paired the same way the PWA is.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String

    var body: some View {
        NavigationStack {
            Group {
                if let pairing = model.pairing {
                    ReportWebView(pairing: pairing, id: id) { dismiss() }
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
    }
}

struct ReportWebView: UIViewRepresentable {
    let pairing: Pairing
    let id: String
    let onBack: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // report.html reads the token from localStorage, like inside the PWA. Only injected on the paired host.
        let token = (try? JSONEncoder().encode(pairing.token)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let host = (try? JSONEncoder().encode(pairing.baseURL.host() ?? "")).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let script = "if (location.hostname === \(host)) { try { localStorage.setItem('elio.token', \(token)); } catch (e) {} }"
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.bg)
        web.navigationDelegate = context.coordinator
        var c = URLComponents(url: pairing.baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/report.html"
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        if let url = c.url { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(host: pairing.baseURL.host() ?? "", onBack: onBack) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let host: String
        let onBack: () -> Void
        init(host: String, onBack: @escaping () -> Void) { self.host = host; self.onBack = onBack }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            // The page's "back to Workflow" link: close the sheet instead.
            if url.host() == host, url.path == "/" || url.path == "/index.html" {
                decisionHandler(.cancel)
                onBack()
                return
            }
            // Stay on the Mac: anything else opens outside the app.
            if url.host() != host {
                decisionHandler(.cancel)
                if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
                return
            }
            decisionHandler(.allow)
        }
    }
}
