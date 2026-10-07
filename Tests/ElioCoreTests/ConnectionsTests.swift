import Foundation
import Testing
@testable import ElioCore

struct SQLClassifierTests {
    @Test func splitsStatementsRespectingLiteralsAndComments() {
        let sql = """
        SELECT 'a;b' AS x; -- comment; here
        /* block; */ UPDATE t SET s = "x;y" WHERE id = 1;
        SELECT `weird;col` FROM t
        """
        let parts = SQLText.split(sql)
        #expect(parts.count == 3)
        #expect(parts[0] == "SELECT 'a;b' AS x")
        #expect(parts[2] == "SELECT `weird;col` FROM t")
        #expect(SQLText.split("-- only a comment\n;;  ").isEmpty)
        // Postgres dollar quoting.
        let fn = "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql; SELECT 1"
        #expect(SQLText.split(fn, dialect: .postgres).count == 2)
        #expect(SQLText.isUnterminated("SELECT 'abc"))
        #expect(!SQLText.isUnterminated("SELECT 'it''s'"))
    }

    @Test func readOnly() {
        #expect(SQLText.isReadOnly("SELECT * FROM sales_order WHERE entity_id = 5"))
        #expect(SQLText.isReadOnly("  -- why\n/* c */ show tables; describe catalog_product_entity; EXPLAIN SELECT 1"))
        #expect(SQLText.isReadOnly("WITH x AS (SELECT 1 AS a) SELECT a FROM x", dialect: .postgres))
        #expect(SQLText.isReadOnly("SELECT 'DELETE FROM t' AS s"))         // keyword inside a literal
        #expect(!SQLText.isReadOnly("SELECT * FROM t INTO OUTFILE '/tmp/x'"))
        #expect(!SQLText.isReadOnly("SELECT * INTO new_t FROM t", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT * FROM t FOR UPDATE"))
        #expect(!SQLText.isReadOnly("SELECT * FROM t LOCK IN SHARE MODE"))
        #expect(!SQLText.isReadOnly("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT 1; DELETE FROM t"))
        #expect(!SQLText.isReadOnly("EXPLAIN ANALYZE DELETE FROM t", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT pg_terminate_backend(123)", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT lo_export(1, '/tmp/x')", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT set_config('a', 'b', false)", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT dblink_exec('x', 'drop table t')", dialect: .postgres))
        #expect(!SQLText.isReadOnly("COPY t TO PROGRAM 'id'", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT LOAD_FILE('/etc/passwd')"))
        // Quoted and schema-qualified calls.
        #expect(!SQLText.isReadOnly(#"SELECT "pg_terminate_backend"(123)"#, dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT pg_catalog.pg_terminate_backend(1)", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT `sleep`(10)"))
        #expect(!SQLText.isReadOnly("SELECT BENCHMARK(1000000, MD5('a'))"))
        #expect(!SQLText.isReadOnly("SELECT GET_LOCK('x', 10)"))
        // Postgres allowlist: unknown functions go through the confirmation.
        #expect(!SQLText.isReadOnly("SELECT my_custom_fn(1)", dialect: .postgres))
        #expect(!SQLText.isReadOnly("SELECT nextval('s')", dialect: .postgres))
        #expect(!SQLText.isReadOnly(#"SELECT U&"!0070g_terminate_backend" UESCAPE '!'(1)"#, dialect: .postgres))
        #expect(!SQLText.isReadOnly(#"SELECT u&"d0070g_sleep"(1)"#, dialect: .postgres))
        #expect(!SQLText.isReadOnly(#"SELECT "count"(*) FROM t"#, dialect: .postgres))
        #expect(SQLText.isReadOnly("SELECT count(*), max(created_at), lower(name) FROM users WHERE id IN (1, 2) GROUP BY name", dialect: .postgres))
        #expect(SQLText.isReadOnly("SELECT COUNT(*) FROM sales_order WHERE created_at > NOW() - INTERVAL 1 DAY"))
        #expect(!SQLText.isReadOnly("UPDATE t SET a = 1"))
        #expect(!SQLText.isReadOnly("PRAGMA journal_mode = DELETE", dialect: .sqlite))
        #expect(SQLText.isReadOnly("PRAGMA table_info", dialect: .sqlite))
        #expect(!SQLText.isReadOnly(""))
        #expect(!SQLText.isReadOnly("SELECT 'open"))
    }

    @Test func executableCommentsAreNeverReadOnly() {
        #expect(!SQLText.isReadOnly("SELECT 1 /*!50000 , (DROP TABLE x) */"))
        #expect(!SQLText.isReadOnly("/*!50000 DROP TABLE x */"))
        #expect(!SQLText.isReadOnly("SELECT /*! SLEEP(1) */ 1"))
        #expect(!SQLText.isReadOnly("SELECT 1 /*M! , 2 */"))
        #expect(SQLText.isReadOnly("SELECT 1 /* plain comment */"))
        #expect(SQLText.isReadOnly("SELECT '/*!50000 x */' AS s"))   // inside a literal it's text
    }

    @Test func clientCommandsAreRefused() {
        // Postgres: any backslash at all (E-strings included).
        #expect(SQLText.hasClientCommand(#"SELECT E'\' ; \! id ; '"#, dialect: .postgres))
        #expect(SQLText.hasClientCommand(#"\! id"#, dialect: .postgres))
        #expect(SQLText.hasClientCommand(#"SELECT E'a\nb'"#, dialect: .postgres))
        #expect(SQLText.hasClientCommand("SELECT $$ \\! id $$", dialect: .postgres))
        #expect(!SQLText.hasClientCommand("SELECT 'a' || $$b$$", dialect: .postgres))
        #expect(!SQLText.isReadOnly(#"SELECT E'\' ; \! id ; '"#, dialect: .postgres))
        // E-string lexing: the escaped quote doesn't close it, so this is one statement.
        #expect(SQLText.split(#"SELECT E'it\'s; fine'"#, dialect: .postgres).count == 1)
        // MySQL.
        #expect(SQLText.hasClientCommand(#"\! id"#, dialect: .mysql))
        #expect(SQLText.hasClientCommand("system id", dialect: .mysql))
        #expect(SQLText.hasClientCommand("SELECT 1; source /tmp/x.sql", dialect: .mysql))
        #expect(!SQLText.hasClientCommand("SELECT id,\nstatus\nFROM sales_order", dialect: .mysql))
        #expect(!SQLText.hasClientCommand(#"SELECT 'a\'b'"#, dialect: .mysql))
        // SQLite dot-commands.
        #expect(SQLText.hasClientCommand(".shell id", dialect: .sqlite))
        #expect(SQLText.hasClientCommand("SELECT 1;\n.system id", dialect: .sqlite))
        #expect(SQLText.hasClientCommand("SELECT 1\n.shell id", dialect: .sqlite))
        #expect(!SQLText.hasClientCommand("SELECT t.a FROM t", dialect: .sqlite))
    }

    @Test func destructive() {
        #expect(SQLText.destructiveReason("DELETE FROM t") != nil)
        #expect(SQLText.destructiveReason("delete from t where id = 1") == nil)
        #expect(SQLText.destructiveReason("UPDATE t SET a = 'WHERE'") != nil)   // WHERE in a literal doesn't count
        #expect(SQLText.destructiveReason("DROP TABLE x") != nil)
        #expect(SQLText.destructiveReason("TRUNCATE x") != nil)
        #expect(SQLText.destructiveReason("ALTER TABLE x ADD c INT") != nil)
        #expect(SQLText.destructiveReason("INSERT INTO x VALUES (1)") == nil)
    }

    @Test func limits() {
        #expect(SQLText.withLimit("SELECT * FROM t;", 1001) == "SELECT * FROM t\nLIMIT 1001")
        #expect(SQLText.withLimit("SELECT * FROM t -- c", 10).hasSuffix("\nLIMIT 10"))
        #expect(SQLText.withLimit("SELECT * FROM t LIMIT 5", 10) == "SELECT * FROM t LIMIT 5")
        #expect(SQLText.withLimit("UPDATE t SET a=1", 10) == "UPDATE t SET a=1")
        #expect(SQLText.withLimit("SELECT * FROM t FOR UPDATE", 10) == "SELECT * FROM t FOR UPDATE")
        #expect(SQLText.returnsRows("INSERT INTO t VALUES (1) RETURNING id", dialect: .postgres))
        #expect(!SQLText.returnsRows("UPDATE t SET a = 1"))
    }
}

struct ShellClassifierTests {
    @Test func readOnlyCommands() {
        #expect(ShellCommandClassifier.isReadOnly("ls -la /var/www"))
        #expect(ShellCommandClassifier.isReadOnly("tail -n 200 var/log/system.log"))
        #expect(ShellCommandClassifier.isReadOnly("ps aux | grep php-fpm"))
        #expect(ShellCommandClassifier.isReadOnly("df -h"))
        #expect(ShellCommandClassifier.isReadOnly("git status"))
        #expect(ShellCommandClassifier.isReadOnly("git log --oneline -n 20"))
        #expect(ShellCommandClassifier.isReadOnly("find . -name '*.log' -mtime -1"))
        for glob in ["ls *", "cat var/log/*.log", "ls ~", "ls file?", "ls [a-z]", "du -sh ~/backups"] {
            #expect(!ShellCommandClassifier.isReadOnly(glob), "\(glob)")
        }
        #expect(ShellCommandClassifier.isReadOnly("grep -rn 'Exception' var/log"))
        #expect(ShellCommandClassifier.isReadOnly("du -sh '/var/backups'"))
        #expect(ShellCommandClassifier.isReadOnly("ls -la 'var/log/*.log'"))   // quoted: no expansion
        #expect(ShellCommandClassifier.isReadOnly("tail -n100 var/log/exception.log"))
        #expect(ShellCommandClassifier.isReadOnly("git diff --stat"))
    }

    @Test func refusesAnythingRisky() {
        let bad = [
            "rm -rf /", "ls > /tmp/x", "cat a >> b", "ls; rm x", "ls && rm x", "ls || rm x", "ls & rm x",
            "echo $(id)", "echo `id`", "cat <<< x", "ls $HOME", "sudo ls", "FOO=1 ls", "/tmp/ls",
            "rg --pre=sh x", "rg --pre-glob '*' x", "rg -z x",
            "sort --compress-program=sh a", "sort -o out in", "uniq in out", "tree -o out",
            "find . -exec rm {} \\;", "find . -delete", "find . -fprint /tmp/x", "find . -execdir id ';'",
            "awk 'BEGIN{system(\"id\")}'", "sed -i s/a/b/ f", "xargs rm", "env", "tee x", "less f", "more f",
            "git -c core.pager=id log", "git log --output=/tmp/x", "git branch new", "git checkout x", "git push",
            "tail -f log", "date -s 2020-01-01", "date --set=now", "date 010100002020", "hostname evil",
            "ls\nrm x", "systemctl restart nginx", "docker rm x", "journalctl --vacuum-size=1M", "crontab -r",
            "ls | sh", "cat f | bash", "tree -Lo 1 out", "tree", "tail -nfoo x", "head -n -c x", "grep -f patterns x",
            "grep --include=x y", "git log --format=%H", "find . -newer x", "find . -name x -o -exec id ;",
            "ls -la a b c d e f g h i j k", "date", "hostname",
        ]
        for cmd in bad { #expect(!ShellCommandClassifier.isReadOnly(cmd), "\(cmd)") }
    }
}

struct ResultParsingTests {
    @Test func mysqlXML() {
        let xml = """
        <?xml version="1.0"?>

        <resultset statement="select * from tt" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <row>
        \t<field name="id">1</field>
        \t<field name="name">a&lt;b &amp; &quot;c&quot;</field>
        \t<field name="n">1.50</field>
          </row>

          <row>
        \t<field name="id">2</field>
        \t<field name="name"></field>
        \t<field name="n" xsi:nil="true" />
          </row>
        </resultset>
        <?xml version="1.0"?>

        <resultset statement="select row_count() as __elio_affected" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <row>
        \t<field name="__elio_affected">-1</field>
          </row>
        </resultset>
        <?xml version="1.0"?>

        <resultset statement="select * from tt where id&gt;9" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"></resultset>
        """
        let sets = MySQLXML.parse(xml)
        #expect(sets.count == 3)
        #expect(sets[0].columns == ["id", "name", "n"])
        #expect(sets[0].rows == [["1", "a<b & \"c\"", "1.50"], ["2", "", nil]])
        #expect(sets[1].columns == ["__elio_affected"])
        #expect(sets[2].statement == "select * from tt where id>9" && sets[2].rows.isEmpty)
    }

    @Test func psqlCSV() {
        let csv = "id,name,n\n1,\"a,b\",1.5\n2,,\u{1}ELIONULL\u{1}\n3,\"line1\nline2\",3\n"
        let r = CSVText.parse(csv)
        #expect(r.count == 4)
        #expect(r[0] == ["id", "name", "n"])
        #expect(r[1] == ["1", "a,b", "1.5"])
        #expect(r[2] == ["2", "", "\u{1}ELIONULL\u{1}"])
        #expect(r[3] == ["3", "line1\nline2", "3"])
        #expect(CSVText.field("a\"b") == "\"a\"\"b\"" && CSVText.field(nil) == "")
    }

    @Test func sqliteQuote() {
        let out = "'id','name','b'\n1,'a,b',X'0102'\n2,'',NULL\n3,'it''s\nline2',NULL\n"
        let r = SQLiteQuote.parse(out)
        #expect(r.count == 4)
        #expect(r[0] == ["id", "name", "b"])
        #expect(r[1] == ["1", "a,b", "0x0102"])
        #expect(r[2] == ["2", "", nil])
        #expect(r[3] == ["3", "it's\nline2", nil])
        #expect(r[2][1] != nil)   // empty string is not NULL
    }

    @Test func remoteListing() {
        let text = "d\td\t4096\t1700000000.5\t755\twww\tapp\nf\tf\t12\t1700000001.0\t644\twww\tindex.php\nl\td\t7\t1700000002\t777\twww\tcurrent\n"
        let e = RemoteFS.parseListing(text)
        #expect(e.map(\.name) == ["app", "current", "index.php"])
        #expect(e[1].dictionary["dir"] as? Bool == true && e[1].dictionary["link"] as? Bool == true)
        #expect(e[2].size == 12 && e[2].mode == "644")
    }
}

struct ConnectionStoreTests {
    @Test func sshConfig() {
        let text = """
        Host *
          ServerAliveInterval 30
        Host staging stage
          HostName 10.0.0.5
          User deploy
          Port 2222
          IdentityFile ~/.ssh/id_ed25519
        Host prod-*
          User root
        Host prod
          HostName=prod.example.com
          ProxyJump bastion
        Match host x
          User nope
        Host -oProxyCommand=id
          HostName evil
        """
        let hosts = SSHConfigHost.parse(text)
        #expect(hosts.map(\.alias) == ["staging", "stage", "prod"])
        #expect(hosts[0].hostName == "10.0.0.5" && hosts[0].user == "deploy" && hosts[0].port == 2222)
        #expect(hosts[0].identityFile == "~/.ssh/id_ed25519")
        #expect(hosts[2].hostName == "prod.example.com" && hosts[2].proxyJump == "bastion")
    }

    @Test func oldFileStillDecodes() {
        // A bare array with only a few fields (older/hand-written file).
        let old = #"[{"id":"ab12","name":"Staging","kind":"ssh","host":"1.2.3.4","user":"deploy"},{"kind":"mysql","host":"db","port":"x"}]"#
        let list = ConnectionStore.decode(Data(old.utf8))
        #expect(list.count == 2)
        #expect(list[0].auth == .agent && list[0].forwards.isEmpty && !list[0].production)
        #expect(list[1].name == "db" && list[1].port == nil && list[1].effectivePort == 3306)
        // Current shape.
        let cur = #"{"version":1,"connections":[{"id":"x1","name":"Magento","kind":"mysql","host":"127.0.0.1","port":3306,"production":true,"unknown":1}]}"#
        let l2 = ConnectionStore.decode(Data(cur.utf8))
        #expect(l2.first?.production == true && l2.first?.port == 3306)
    }

    @Test func fromArgsAndFind() {
        let c = Connection.from(["kind": "ssh", "host": "1.2.3.4", "user": "deploy", "port": "2222", "remote_dir": "/var/www"])
        #expect(c.port == 2222 && c.remoteDir == "/var/www" && c.name == "1.2.3.4")
        let list = [c, Connection(name: "DB staging", kind: .mysql, host: "db.staging")]
        #expect(ConnectionStore.find("staging", in: list)?.kind == .mysql)
        #expect(ConnectionStore.find(c.id, in: list)?.id == c.id)
        #expect(ConnectionStore.find("1.2.3.4", in: list)?.id == c.id)
    }

    @Test func secretsAreBoundToTheEndpoint() {
        let c = Connection(name: "Prod", kind: .mysql, host: "db.prod", port: 3306, user: "magento", database: "m2")
        #expect(ConnectionSecrets.matches(stored: c.endpointFingerprint, c))
        var moved = c; moved.host = "attacker.example"
        #expect(moved.endpointChanged(from: c))
        #expect(!ConnectionSecrets.matches(stored: c.endpointFingerprint, moved))
        var other = c; other.user = "root"
        #expect(other.endpointChanged(from: c) && !ConnectionSecrets.matches(stored: c.endpointFingerprint, other))
        var alias = c; alias.sshConfigAlias = true
        #expect(alias.endpointChanged(from: c))
        var tunnel = c; tunnel.sshVia = "abcd"
        #expect(tunnel.endpointChanged(from: c))
        var renamed = c; renamed.name = "Produzione"; renamed.production = true; renamed.color = "red"
        #expect(!renamed.endpointChanged(from: c))   // cosmetic changes keep the password
        #expect(!ConnectionSecrets.matches(stored: nil, c))  // items saved without a fingerprint are not used
    }

    @Test func validationRefusesOptionSmuggling() {
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .ssh, host: "-oProxyCommand=sh -c id").validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .ssh, host: "a b").validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .ssh, host: "h", user: "-oX").validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .ssh, host: "h", user: "a@b").validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .ssh, host: "h", port: 70000).validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .ssh, host: "h", auth: .key, keyPath: "/etc/passwd").validate() }
        #expect(throws: ToolError.self) {
            try Connection(name: "x", kind: .ssh, host: "h", forwards: [.init(localPort: 8080, remoteHost: "-oX", remotePort: 80)]).validate()
        }
        #expect(throws: Never.self) { try Connection(name: "x", kind: .ssh, host: "deploy.example.com", port: 22, user: "deploy").validate() }
        #expect(throws: Never.self) { try Connection(name: "x", kind: .ssh, host: "[::1]").validate() }
        #expect(throws: ToolError.self) { try ConnectionSecrets.validatePassword("pw\nFLUSHALL") }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .redis, host: "h", user: "a b").validate() }
        #expect(throws: Never.self) { try ConnectionSecrets.validatePassword("p@ss w0rd!#") }
        #expect(throws: Never.self) { try Connection(name: "x", kind: .mysql).validate() }   // local socket
        #expect(SSHRunner.options(Connection(name: "x", kind: .ssh, host: "h")).contains("BatchMode=yes"))
        // Postgres conninfo smuggling and option-file injection through the database name.
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .postgres, host: "h", database: "host=evil dbname=x").validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .postgres, host: "h", database: "postgres://evil/x").validate() }
        #expect(throws: ToolError.self) { try Connection(name: "x", kind: .mysql, host: "h", database: "db\ninit-command=DROP DATABASE x").validate() }
        #expect(throws: Never.self) { try Connection(name: "x", kind: .mysql, host: "h", database: "magento_2-4").validate() }
        #expect(PGConnInfo.build(host: "h", port: 5432, user: "u", dbname: "a' host='evil") == #"dbname='a\' host=\'evil' user='u' host='h' port=5432"#)
    }
}

/// Real clients: SQLite on a temp file always; Postgres/Redis only when ELIO_SMOKE_PG / ELIO_SMOKE_REDIS
/// point at throwaway local servers ("host:port:user:password").
struct DBSessionSmokeTests {
    @Test func sqliteRoundTrip() throws {
        guard DBClients.client(for: .sqlite) != nil else { return }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("elio-smoke-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = DBSession(connection: Connection(name: "t", kind: .sqlite, path: path))
        try s.start(password: nil)
        defer { s.close() }
        #expect(!s.serverVersion.isEmpty)
        let r = try s.run("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('a'), (''), (NULL); SELECT * FROM t; SELECT * FROM nope; SELECT 1")
        #expect(r.count == 4)   // stops at the error
        #expect(r[1].affected == 3)
        #expect(r[2].columns == ["id", "name"] && r[2].rows == [["1", "a"], ["2", ""], ["3", nil]])
        #expect(r[3].error?.contains("nope") == true)
        let more = try s.run("SELECT * FROM t", maxRows: 2)
        #expect(more[0].rows.count == 2 && more[0].truncated)
        try s.setAutocommit(false)
        _ = try s.run("DELETE FROM t")
        _ = try s.commit(false)
        #expect(try s.run("SELECT count(*) FROM t")[0].rows == [["3"]])
        #expect(throws: ToolError.self) { try s.run(".shell id") }
        // Read-only session refuses writes in the engine itself.
        let ro = DBSession(connection: Connection(name: "t", kind: .sqlite, path: path), readOnly: true)
        try ro.start(password: nil)
        defer { ro.close() }
        #expect(try ro.run("DELETE FROM t")[0].error != nil)
    }

    static func env(_ k: String) -> [String]? {
        ProcessInfo.processInfo.environment[k].map { $0.split(separator: ":", omittingEmptySubsequences: false).map(String.init) }
    }

    @Test func postgresRoundTrip() throws {
        guard let e = Self.env("ELIO_SMOKE_PG"), e.count == 4 else { return }
        let c = Connection(name: "pg", kind: .postgres, host: e[0], port: Int(e[1]), user: e[2], database: "postgres")
        let s = DBSession(connection: c)
        try s.start(password: e[3])
        defer { s.close() }
        #expect(!s.serverVersion.isEmpty)
        let r = try s.run("CREATE TEMP TABLE t(id int primary key, name text); INSERT INTO t VALUES (1,'a,b'),(2,''),(3,NULL); SELECT * FROM t ORDER BY id; SELECT * FROM nope")
        #expect(r[1].affected == 3)
        #expect(r[2].rows == [["1", "a,b"], ["2", ""], ["3", nil]])
        #expect(r[3].error != nil)
        #expect(throws: ToolError.self) { try s.run(#"SELECT E'\' ; \! id ; '"#) }
        let ro = DBSession(connection: c, readOnly: true)
        try ro.start(password: e[3])
        defer { ro.close() }
        #expect(try ro.run("CREATE TABLE x(a int)")[0].error != nil)
        let bad = DBSession(connection: c)
        #expect(throws: ToolError.self) { try bad.start(password: "wrong") }
    }

    @Test func redisRoundTrip() throws {
        guard let e = Self.env("ELIO_SMOKE_REDIS"), e.count == 4 else { return }
        let s = DBSession(connection: Connection(name: "r", kind: .redis, host: e[0], port: Int(e[1])))
        try s.start(password: e[3])
        defer { s.close() }
        let r = try s.run("SET elio:k \"hello world\"\nGET elio:k\nNOPE")
        #expect(r[1].text == "\"hello world\"")
        #expect(r[2].error != nil)
    }
}
