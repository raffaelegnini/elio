import Foundation
import Testing
@testable import ElioCore

struct SQLAutonomousReadTests {
    @Test func unicodeSpaceAfterDashesIsNotAMySQLComment() {
        let attack = "SELECT 1 --\u{00A0}x; SET SESSION TRANSACTION READ WRITE; DELETE FROM users"
        #expect(!SQLText.isReadOnly(attack, dialect: .mysql))
        #expect(!SQLText.isAutonomousRead(attack, dialect: .mysql))
        // Real comments still are.
        #expect(SQLText.isReadOnly("SELECT 1 -- note; DELETE FROM users", dialect: .mysql))
        #expect(SQLText.isReadOnly("SELECT 1 --\tnote", dialect: .mysql))
        #expect(SQLText.isReadOnly("SELECT 1 --", dialect: .mysql))
    }

    @Test func crlfEndsLineComments() {
        // "\r\n" is one Character in Swift: the comment must still end there.
        #expect(!SQLText.isReadOnly("SELECT 1 # x\r\n; DELETE FROM users", dialect: .mysql))
        #expect(!SQLText.isReadOnly("SELECT 1 -- x\r\n; DELETE FROM users", dialect: .mysql))
        // psql ends a comment at a lone "\r" too.
        #expect(!SQLText.isReadOnly("SELECT 1 -- x\rDELETE FROM users", dialect: .postgres))
    }

    @Test func combiningMarksCantHideQuotes() {
        let attack = "SELECT '\u{301} ' ; DELETE FROM users; SELECT '"
        #expect(!SQLText.isReadOnly(attack, dialect: .mysql))
        #expect(SQLText.isReadOnly("SELECT 'caffè' AS x", dialect: .mysql))   // precomposed letters are fine
    }

    @Test func autonomousReadsAreOnePlainStatement() {
        #expect(SQLText.isAutonomousRead("SELECT id, name FROM users WHERE id = 3", dialect: .mysql))
        #expect(SQLText.isAutonomousRead("SELECT 1;", dialect: .mysql))
        #expect(SQLText.isAutonomousRead("SELECT 1 -- note\nFROM dual", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT 1; SELECT 2", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT ';' AS x", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT 'a\\'b'", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT /* x */ 1", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT\u{00A0}1", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT 1\u{200B}", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT 1\r\nFROM dual", dialect: .mysql))
        #expect(!SQLText.isAutonomousRead("SELECT 1\u{2028}", dialect: .postgres))
        #expect(!SQLText.isAutonomousRead("DELETE FROM users", dialect: .mysql))
    }
}

struct ConnectionToolSafetyTests {
    @Test func onlyDocumentedFieldsFromTheAssistant() {
        let keys = ConnectionTools.documentedKeys
        for k in ["verified", "forwards", "localRoot", "remoteRoot", "sshConfigAlias", "sshVia", "keyPath", "auth", "id"] {
            #expect(!keys.contains(k), "\(k)")
        }
        #expect(keys.isSuperset(of: ["kind", "name", "host", "port", "user", "database", "ssh_via", "production"]))
    }

    @Test func nameAndProductionChangesNeedConfirmation() {
        var old = Connection(name: "Staging", kind: .mysql)
        old.host = "10.0.0.1"; old.user = "app"; old.database = "shop"; old.production = true
        var renamed = old
        renamed.name = "Locale"; renamed.production = false
        let changes = ConnectionTools.settingsChanges(old, renamed)
        #expect(changes.count == 2)
        #expect(ConnectionTools.settingsChanges(old, old).isEmpty)
        var moved = old
        moved.forwards = [.init(localPort: 1, remoteHost: "x", remotePort: 2)]
        moved.localRoot = "/tmp/a"
        #expect(ConnectionTools.settingsChanges(old, moved).count == 2)
        // The dialog shows where it really goes, and a loud production marker.
        let t = ConnectionTools.confirmTarget(old)
        #expect(t.contains("app@10.0.0.1:3306/shop") && t.contains("PRODUZIONE"))
    }

    @Test func tunnelHostIsFoundByExactIdOnly() {
        var a = Connection(name: "bastion", kind: .ssh); a.host = "1.1.1.1"
        var b = Connection(name: "bastion-evil", kind: .ssh); b.host = "6.6.6.6"
        let list = [b, a]
        #expect(ConnectionStore.byId(a.id, kinds: [.ssh], in: list)?.host == "1.1.1.1")
        #expect(ConnectionStore.byId("bastion", kinds: [.ssh], in: list) == nil)
        #expect(ConnectionStore.byId("", in: list) == nil)
    }
}

struct SSHControlDirTests {
    @Test func refusesSymlinksAndFixesMode() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("elio-cd-\(UUID().uuidString.prefix(6))").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let real = base + "/real", link = base + "/link", loose = base + "/loose"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(!SSHRunner.ensurePrivateDir(link))
        try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o777])
        #expect(SSHRunner.ensurePrivateDir(loose))
        #expect(SSHRunner.isPrivateDir(loose))
        #expect(SSHRunner.ensurePrivateDir(base + "/fresh"))
        #expect(SSHRunner.isPrivateDir(SSHRunner.controlDir))
    }
}
