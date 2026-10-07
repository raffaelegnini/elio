#if DEBUG
import Foundation

/// Sample content for screenshots and SwiftUI previews (launch with `-ElioDemo`). Debug builds only.
extension AppModel {
    static var demoRequested: Bool { ProcessInfo.processInfo.arguments.contains("-ElioDemo") }

    func loadDemo() {
        tasksForDemo([
            TaskInfo(id: "t1", title: "Export CSV ordini", project: "shop", status: "running",
                     steps: ["Scrivo i test dell'export"], summary: nil, kind: "code", member: "Ada", role: nil, lastMessage: nil, costUSD: 0.42),
        ])
        feedForDemo([
            FeedItem(kind: .user, text: "Elio, a che punto è l'export degli ordini?"),
            FeedItem(kind: .elio, text: "Ada sta scrivendo i test: la parte di export è pronta, manca la paginazione. Finisce entro mezz'ora.", meta: "claude · 2140 ms"),
            FeedItem(kind: .event, text: "Promemoria: chiamata con Marco alle 16:30."),
            FeedItem(kind: .confirm(ConfirmRequest(id: "c1", title: "Faccio il push su main?", detail: "git push origin main", risk: "normal")), text: ""),
            FeedItem(kind: .question(QuestionRequest(id: "q1", question: "Per la paginazione uso 50 o 100 righe per pagina?", from: "Ada")), text: ""),
        ])
        let now = Date()
        inbox.demo([
            InboxMessage(id: "m1", title: "Riepilogo della mattina", text: "Tre PR approvate, una in attesa di review. Il monitor del sito non ha segnalato problemi.", source: "elio", date: now.addingTimeInterval(-600), read: false),
            InboxMessage(id: "m2", title: "Sito clienti: tempi di risposta alti", text: "Tra le 10:12 e le 10:20 la home ha risposto in oltre 3 secondi. Ora è tornata normale.", source: "monitor:sito", date: now.addingTimeInterval(-7200), read: false),
            InboxMessage(id: "m3", title: "Report squadra pronto", text: "La squadra ha finito la migrazione del database: tutto verde.", source: nil, date: now.addingTimeInterval(-90000), read: true),
        ])
    }
}

extension InboxModel {
    func demo(_ messages: [InboxMessage]) { setForDemo(messages) }
}
#endif
