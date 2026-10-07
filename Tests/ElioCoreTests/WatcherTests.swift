import Foundation
import Testing
@testable import ElioCore

struct WatcherTests {
    @Test func oldWatchersFileStillDecodes() throws {
        let json = """
        [{"id":"ab12cd34","name":"Kuma","enabled":true,"trigger":"slack","weekdaysOnly":false,"channel":"kuma-ops",
          "match":"down","action":"agent","prompt":"analizza","cooldownMinutes":30,"lastCheck":"2026-09-01T10:00:00Z",
          "state":"1725184800.000100"}]
        """
        let list = try JSONDecoder.iso.decode([Watcher].self, from: Data(json.utf8))
        #expect(list.count == 1)
        let w = list[0]
        #expect(w.trigger == .slack && w.action == .agent && w.channel == "kuma-ops")
        #expect(w.urgency == .notify && !w.phone && !w.once && w.everySeconds == nil && w.seen == nil)
        #expect(w.lastCheck != nil && w.state == "1725184800.000100")
        // Round trip with the new fields.
        var n = w
        n.urgency = .call; n.once = true; n.seen = ["a"]
        let back = try JSONDecoder.iso.decode(Watcher.self, from: JSONEncoder.iso.encode(n))
        #expect(back == n)
    }

    @Test func httpModes() {
        // down: fires once when it goes down, recovers when it's back.
        #expect(WatchRules.http(fireOn: nil, ok: false, matched: false, hash: nil, previous: "up") == .init(fire: true, state: "down"))
        #expect(WatchRules.http(fireOn: nil, ok: false, matched: false, hash: nil, previous: "down").fire == false)
        #expect(WatchRules.http(fireOn: "down", ok: true, matched: false, hash: "h", previous: "down").recovered)
        // up: fires as soon as it answers, even on the first check.
        #expect(WatchRules.http(fireOn: "up", ok: true, matched: false, hash: "h", previous: nil).fire)
        #expect(WatchRules.http(fireOn: "up", ok: false, matched: false, hash: nil, previous: nil) == .init(fire: false, state: "down"))
        #expect(WatchRules.http(fireOn: "up", ok: true, matched: false, hash: "h", previous: "up").fire == false)
        // change: first hash is the baseline, errors don't count.
        #expect(WatchRules.http(fireOn: "change", ok: true, matched: false, hash: "a", previous: nil) == .init(fire: false, state: "a"))
        #expect(WatchRules.http(fireOn: "change", ok: false, matched: false, hash: nil, previous: "a") == .init(fire: false, state: "a"))
        #expect(WatchRules.http(fireOn: "change", ok: true, matched: false, hash: "b", previous: "a").fire)
        // match: on the transition only.
        #expect(WatchRules.http(fireOn: "match", ok: true, matched: true, hash: "a", previous: "nomatch").fire)
        #expect(WatchRules.http(fireOn: "match", ok: true, matched: true, hash: "a", previous: "match").fire == false)
    }

    @Test func commandModes() {
        #expect(WatchRules.command(fireOn: nil, code: 1, hash: "x", matched: false, previous: "x").fire)
        #expect(WatchRules.command(fireOn: nil, code: 0, hash: "x", matched: false, previous: nil).fire == false)
        #expect(WatchRules.command(fireOn: "change", code: 0, hash: "x", matched: false, previous: nil).fire == false)
        #expect(WatchRules.command(fireOn: "change", code: 0, hash: "y", matched: false, previous: "x").fire)
        #expect(WatchRules.command(fireOn: "success", code: 7, hash: "x", matched: false, previous: nil) == .init(fire: false, state: "ko"))
        #expect(WatchRules.command(fireOn: "success", code: 0, hash: "x", matched: false, previous: "ko").fire)
        #expect(WatchRules.command(fireOn: "success", code: 0, hash: "x", matched: false, previous: "ok").fire == false)
        #expect(WatchRules.command(fireOn: "match", code: 0, hash: "x", matched: true, previous: nil).fire)
    }

    @Test func screenPresence() {
        #expect(WatchRules.presence(fireOn: nil, present: true, previous: nil, debounce: true).fire)
        #expect(WatchRules.presence(fireOn: "appear", present: true, previous: "present", debounce: true).fire == false)
        // disappear: never seen → wait; seen then two misses → fire.
        #expect(WatchRules.presence(fireOn: "disappear", present: false, previous: nil, debounce: true) == .init(fire: false, state: "absent"))
        let gone1 = WatchRules.presence(fireOn: "disappear", present: false, previous: "present", debounce: true)
        #expect(gone1 == .init(fire: false, state: "gone1"))
        #expect(WatchRules.presence(fireOn: "disappear", present: true, previous: "gone1", debounce: true) == .init(fire: false, state: "present"))
        #expect(WatchRules.presence(fireOn: "disappear", present: false, previous: "gone1", debounce: true).fire)
        #expect(WatchRules.presence(fireOn: "disappear", present: false, previous: "present", debounce: false).fire)
        // A ticking clock is not a change; a new dialog is.
        #expect(!WatchRules.meaningfulChange("Rendering video progetto 10:41 45%", "Rendering video progetto 10:42 46%"))
        #expect(WatchRules.meaningfulChange("Rendering video progetto in corso", "Esportazione completata mostra nel Finder"))
    }

    @Test func downloadsFinish() {
        typealias F = WatchRules.FileInfo
        let old = F(path: "/d/old.zip", size: 10, mtime: 1)
        // First check: what's there is the baseline.
        let first = WatchRules.filesAppeared([old, F(path: "/d/new.zip.crdownload", size: 5, mtime: 2)], seen: nil, lastSizes: [:]) { _ in false }
        #expect(first.ready.isEmpty && first.seen == ["/d/old.zip|1"])
        // The renamed download shows up: wait one check for a stable size.
        let new = F(path: "/d/new.zip", size: 50, mtime: 3)
        let second = WatchRules.filesAppeared([old, new], seen: first.seen, lastSizes: [:]) { _ in false }
        #expect(second.ready.isEmpty)
        let third = WatchRules.filesAppeared([old, new], seen: second.seen, lastSizes: ["/d/new.zip": 50]) { _ in false }
        #expect(third.ready == [new])
        // Firefox: placeholder plus .part → not yet.
        let ff = WatchRules.filesAppeared([new], seen: first.seen, lastSizes: ["/d/new.zip": 50]) { _ in true }
        #expect(ff.ready.isEmpty)
        // Already notified: not again.
        #expect(WatchRules.filesAppeared([old, new], seen: third.seen, lastSizes: ["/d/new.zip": 50]) { _ in false }.ready.isEmpty)
        #expect(WatchRules.isTempDownload("/d/a.part") && !WatchRules.isTempDownload("/d/a.pdf"))
    }

    @Test func seenIdsStayBounded() {
        let a = WatchRules.mergeSeen([], (0..<150).map(String.init), limit: 200)
        let b = WatchRules.mergeSeen(a, (100..<300).map(String.init), limit: 200)
        #expect(b.count == 200 && b.first == "100" && b.last == "299")
        #expect(WatchRules.mergeSeen(["x"], ["x", "y"], limit: 200) == ["x", "y"])
    }

    @Test func pipelineInputs() {
        let r = WatchRules.parseRunURL("https://github.com/dnafactory/elio/actions/runs/123456789/job/42")
        #expect(r?.repo == "dnafactory/elio" && r?.id == "123456789")
        #expect(WatchRules.parseRunURL("https://github.com/dnafactory/elio/pull/3") == nil)
        #expect(WatchRules.parseGitHubRemote("git@github.com:dnafactory/elio.git\n") == "dnafactory/elio")
        #expect(WatchRules.parseGitHubRemote("https://github.com/dnafactory/elio") == "dnafactory/elio")
        #expect(WatchRules.parseGitHubRemote("https://gitlab.com/a/b.git") == nil)
        #expect(PipelineSensor.resolveRepo("dnafactory/elio").repo == "dnafactory/elio")
        #expect(WatchRules.conclusionIT("failure") == "fallita")
    }

    @Test func smallParsers() {
        #expect(WatchRules.parseEtime("05:03") == 303)
        #expect(WatchRules.parseEtime("1-02:00:01") == 93601.0)
        #expect(WatchRules.duration(40) == "40 secondi")
        #expect(WatchRules.duration(65 * 60) == "1 ora e 5 minuti")
        #expect(WatchRules.appleMailQuery("from:mario@x.it is:unread") == "mario@x.it")
        #expect(WatchRules.appleMailQuery("subject:\"fattura aprile\"") == "fattura aprile")
        #expect(WatchRules.appleMailQuery("contratto newer_than:1d") == "contratto")
        #expect(WatchRules.senderName("Mario Rossi <mario@x.it>") == "Mario Rossi")
    }

    @Test func defaultOnceByTrigger() {
        var w = Watcher(id: "x", name: "x", trigger: .pipeline, action: .notify)
        #expect(WatcherTools.defaultOnce(w))
        w.trigger = .http; w.fireOn = "up"
        #expect(WatcherTools.defaultOnce(w))
        w.fireOn = nil
        #expect(!WatcherTools.defaultOnce(w))
        w.trigger = .screen; w.everySeconds = 1
        #expect(w.interval == 2)
    }
}
