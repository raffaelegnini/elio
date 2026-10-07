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
            t.plan = [PlanStep(status: "completed", text: "Leggere il brief e i file indicati", doneAt: now.addingTimeInterval(-500)),
                      PlanStep(status: "completed", text: "Aggiungere la rotta e il controller", doneAt: now.addingTimeInterval(-300)),
                      PlanStep(status: status == .done ? "completed" : "in_progress", text: "Scrivere i test", active: step.replacingOccurrences(of: "$ ", with: "Eseguo ")),
                      PlanStep(status: status == .done ? "completed" : "pending", text: "Commit sul branch elio/export-csv")]
            return t
        }
        let tasks = [
            member("t1", "backend", "API Laravel", .running, "$ php artisan test --filter=Export", "Endpoint /api/export pronto, sto scrivendo i test di integrazione.", 182_000, 9_400),
            member("t2", "frontend", "Vue + Tailwind", .waitingConfirmation, "Modifica src/views/Reports.vue", "Bottone Esporta CSV aggiunto, aspetto il contratto definitivo da backend.", 141_000, 7_100),
            member("t3", "test", "Test end-to-end", .done, "$ npx playwright test", "12 test verdi su Chrome e Safari.", 96_000, 4_200),
        ]
        var squad = SquadInfo(id: "a1b2c3", goal: "Export CSV dei report con filtri per data", project: "dna-management-apps",
                              startedAt: now.addingTimeInterval(-900))
        squad.brief = "**Stack**: Laravel 11 + Vue 3. Test: `php artisan test`.\n**Per backend**: `app/Http/Controllers/ReportController.php`."
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
        loop.workflowEvents["a1b2c3"] = [
            WorkflowEvent(id: 1, workflow: "a1b2c3", ts: now.addingTimeInterval(-640), kind: .autoDecision, actor: "elio",
                          text: "Date in ISO 8601, sempre UTC", data: "{\"question\":\"Formato date?\"}"),
            WorkflowEvent(id: 2, workflow: "a1b2c3", ts: now.addingTimeInterval(-200), kind: .tasteCorrection, actor: "elio",
                          text: "Niente gradienti viola", data: "{\"agent\":\"frontend\"}"),
        ]

        let today = TodoDay.key()
        loop.todoBoard = TodoBoard(day: today, today: [
            TodoItem(id: 1, text: "Rivedere la PR dell'export CSV", day: today, priority: 1, estimate: 30, focus: true),
            TodoItem(id: 2, text: "Rispondere a Rosario sul preventivo", day: today, priority: 1, time: "11:00"),
            TodoItem(id: 3, text: "Call con il team prodotto", day: today, time: "15:30"),
            TodoItem(id: 4, text: "Timbrare su Slack", day: today, done: true, parent: 9),
        ], overdue: [TodoItem(id: 5, text: "Aggiornare la documentazione API", day: TodoDay.key(now.addingTimeInterval(-86400)))],
           tomorrow: [TodoItem(id: 6, text: "Deploy in staging", day: nil)], someday: [], recurring: [])
        let size = CGSize(width: 1440, height: 900)
        let state = DashboardState()
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/dashboard.png")
        state.squadMode = true
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/squad.png")
        state.squadMode = false
        save(SquadView(loop: loop, state: state, scrolls: false).frame(width: 1300, height: 700).background(Theme.bg), "\(dir)/squad-panel.png")

        // The live "what Elio is doing" strip, thinking between two tools.
        loop.loadSampleFeed()
        save(ThoughtStrip(loop: loop).background(Theme.bg), "\(dir)/thought-strip.png")
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/dashboard-thinking.png")

        loop.loadSample(tasks: [], squads: [], messages: [], usage: usage, routine: true, lit: ["calendar_events"], state: .speaking)
        save(DashboardView(loop: loop, state: state).frame(width: size.width, height: size.height), "\(dir)/briefing-dormant.png")

        // Code neurons as a folder tree, with the real projects.
        let graph = GraphModel()
        graph.setTree(.codice, ProjectTree.scan(roots: cfg.projectRoots))
        graph.setLeaves(.memoria, (1...12).map { ("\($0)", "Ricordo \($0)", "") })
        graph.setLeaves(.integrazioni, [("slack", "Slack", ""), ("gmail", "Gmail", ""), ("spotify", "Spotify", ""),
                                        ("teamwork", "Teamwork", "")], dimmed: ["gmail"])
        graph.setLeaves(.agenda, [("1", "Standup", ""), ("2", "Review", "")])
        for i in 0..<1500 { graph.step(dt: 1.0 / 60 * 8, time: Double(i) / 60) }
        graph.ageAll()
        loop.loadSample(tasks: [], squads: [], messages: [], usage: usage, routine: false, lit: [], state: .listening)
        save(NeuralGraphView(loop: loop, preset: graph, presetZoom: (2.2, CGSize(width: 520, height: -820)))
                .frame(width: 1400, height: 1000).background(Theme.bg), "\(dir)/graph-zoom.png")
        save(NeuralGraphView(loop: loop, preset: graph).frame(width: 1600, height: 1300).background(Theme.bg), "\(dir)/graph.png")

        // The live Core Animation renderer, through the same frames (checks orientation of text and icons).
        let orb = OrbView(state: .thinking, level: 0.3)
        saveLayers(CGSize(width: 400, height: 400), "\(dir)/orb-live.png") { _ in orb.frame(size: CGSize(width: 400, height: 400), t: 1000) }
        let labelled = VectorFrameSample.labels()
        saveLayers(CGSize(width: 300, height: 120), "\(dir)/labels-live.png") { _ in labelled }

        loop.loadSample(tasks: [], squads: [], messages: [], usage: usage, routine: false, lit: [], state: .thinking)
        save(StatusOrbView(loop: loop).background(Color.gray), "\(dir)/island.png")
    }

    static func saveLayers(_ size: CGSize, _ path: String, _ frame: @escaping (Double) -> VectorFrame) {
        let view = VectorLayerView(frame: CGRect(origin: .zero, size: size))
        view.fps = 0
        view.render = frame
        view.layer?.backgroundColor = NSColor(Theme.bg).cgColor
        view.tick()
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard let layer = view.layer, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Bitmap rows go bottom-up: flip so the PNG reads like the screen.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 2, y: -2)
        layer.render(in: ctx)
        guard let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    static func save(_ view: some View, _ path: String) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.liveLayers, false))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed: \(path)"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// A frame with a label and an icon, to check the live renderer draws them upright.
@MainActor
enum VectorFrameSample {
    static func labels() -> VectorFrame {
        var f = VectorFrame()
        f.circle(CGPoint(x: 40, y: 40), 20, Ink(Theme.accent, width: 1.2), .front)
        f.images.append(PlacedImage(spec: ImageSpec(key: "I|puzzlepiece.extension|t", content: .symbol("puzzlepiece.extension", color: .white)),
                                    rect: CGRect(x: 28, y: 28, width: 24, height: 24), stratum: .icons))
        f.images.append(PlacedImage(spec: ImageSpec(key: "L|t", content: .text("INTEGRAZIONI ↓ in alto", size: 12, color: .white)),
                                    point: CGPoint(x: 150, y: 90)))
        return f
    }
}
