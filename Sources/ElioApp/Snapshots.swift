import AppKit
import ElioCore
import ElioVoice
import SwiftUI

/// `ElioApp --snapshot <dir>`: renders the main views with sample data to PNG files,
/// to check the UI without a screen (CI, remote sessions).
@MainActor
enum Snapshots {
    static func render(to dir: String) {
        let cfg = ElioConfig.load()
        Brand.shared.apply(cfg)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let loop = VoiceLoop(config: cfg, token: "snapshot")
        let now = Date()
        func member(_ id: String, _ name: String, _ role: String, _ status: TaskInfo.Status, _ step: String, _ msg: String,
                    _ tin: Int, _ tout: Int) -> TaskInfo {
            var t = TaskInfo(id: id, title: "\(name): \(role)", project: "dna-management-apps", status: status,
                             steps: ["Legge app/Http/Controllers/ExportController.php", step], startedAt: now.addingTimeInterval(-600))
            t.kind = "squad"; t.squad = "a1b2c3"; t.member = name; t.role = role
            t.tokensIn = tin; t.tokensOut = tout; t.costUSD = Double(tin) / 1_000_000 * 3 + Double(tout) / 1_000_000 * 15
            t.lastMessage = msg
            return t
        }
        let tasks = [
            member("t1", "backend", "API Laravel", .running, "$ php artisan test --filter=Export", "Endpoint /api/export pronto, sto scrivendo i test di integrazione.", 182_000, 9_400),
            member("t2", "frontend", "Vue + Tailwind", .waitingConfirmation, "Modifica src/views/Reports.vue", "Bottone Esporta CSV aggiunto, aspetto il contratto definitivo da backend.", 141_000, 7_100),
            member("t3", "test", "Test end-to-end", .done, "$ npx playwright test", "12 test verdi su Chrome e Safari.", 96_000, 4_200),
        ]
        let squad = SquadInfo(id: "a1b2c3", goal: "Export CSV dei report con filtri per data", project: "dna-management-apps",
                              startedAt: now.addingTimeInterval(-900))
        let msgs = [
            SquadMessage(id: 1, squad: "a1b2c3", from: "elio", to: "tutti", text: "Squadra al lavoro su: Export CSV dei report. Coordinatevi qui.", at: now.addingTimeInterval(-880)),
            SquadMessage(id: 2, squad: "a1b2c3", from: "backend", to: "frontend", text: "GET /api/reports/export?from=&to= → text/csv. Header: Content-Disposition attachment.", at: now.addingTimeInterval(-700)),
            SquadMessage(id: 3, squad: "a1b2c3", from: "frontend", to: "backend", text: "Ok, uso quello. Il filtro date è ISO 8601?", at: now.addingTimeInterval(-650)),
            SquadMessage(id: 4, squad: "a1b2c3", from: "test", to: "elio", text: "Suite e2e verde, 12 test. Branch elio/export-csv.", at: now.addingTimeInterval(-120)),
        ]
        var usage = UsageSnapshot()
        usage.window5h.input = 1_200_000; usage.window5h.output = 84_000; usage.window5h.messages = 212
        usage.today = usage.window5h; usage.windowStart = now.addingTimeInterval(-7200); usage.agentsCostUSD = 4.37
        loop.loadSample(tasks: tasks, squads: [squad], messages: msgs, usage: usage, routine: false, lit: [], state: .listening)

        let size = CGSize(width: 1440, height: 900)
        let state = DashboardState()
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/dashboard.png")
        state.squadMode = true
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/squad.png")
        state.squadMode = false
        save(SquadView(loop: loop, state: state, scrolls: false).frame(width: 1300, height: 700).background(Theme.bg), "\(dir)/squad-panel.png")

        loop.loadSample(tasks: [], squads: [], messages: [], usage: usage, routine: true, lit: ["calendar_events"], state: .speaking)
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/briefing-dormant.png")

        // Code neurons as a folder tree, with the real projects.
        let graph = GraphModel()
        graph.setTree(.codice, ProjectTree.scan(roots: cfg.projectRoots))
        for i in 0..<1500 { graph.step(dt: 1.0 / 60 * 8, time: Double(i) / 60) }
        loop.loadSample(tasks: [], squads: [], messages: [], usage: usage, routine: false, lit: [], state: .listening)
        save(NeuralGraphView(loop: loop, preset: graph).frame(width: 1400, height: 1000).background(Theme.bg), "\(dir)/graph.png")

        loop.loadSample(tasks: [], squads: [], messages: [], usage: usage, routine: false, lit: [], state: .thinking)
        save(IslandView(loop: loop, openDashboard: {}, openSettings: {}).background(Color.gray), "\(dir)/island.png")
    }

    static func save(_ view: some View, _ path: String) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
