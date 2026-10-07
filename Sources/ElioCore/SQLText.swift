import Foundation

/// SQL as text: statement splitting, read-only / destructive classification and LIMIT handling.
/// A small lexer that knows strings, quoted identifiers, comments and Postgres dollar quoting,
/// so keywords inside literals ("DELETE" in a string) never count.
public enum SQLText {
    public enum Dialect: String, Sendable { case mysql, postgres, sqlite }

    struct Token: Equatable {
        enum Kind: Equatable { case word, string, ident, punct, number }
        var kind: Kind
        var text: String      // words uppercased
    }

    /// Statements of a script, without trailing `;`, comment-only pieces dropped.
    public static func split(_ sql: String, dialect: Dialect = .mysql) -> [String] {
        var out: [String] = []
        let chars = Array(sql)
        var start = 0
        var hasCode = false
        scan(chars, dialect: dialect) { kind, range in
            if kind == .punct, chars[range.lowerBound] == ";" {
                if hasCode { out.append(String(chars[start..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)) }
                start = range.upperBound
                hasCode = false
            } else if kind != .comment, kind != .space {
                hasCode = true
            }
        }
        if hasCode { out.append(String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out.filter { !$0.isEmpty }
    }

    /// Where each statement starts and ends in the text (for "run the statement under the cursor").
    public static func ranges(_ sql: String, dialect: Dialect = .mysql) -> [(start: Int, end: Int)] {
        var out: [(Int, Int)] = []
        let chars = Array(sql)
        var start = 0, codeStart = -1
        scan(chars, dialect: dialect) { kind, range in
            if kind == .punct, chars[range.lowerBound] == ";" {
                if codeStart >= 0 { out.append((codeStart, range.upperBound)) }
                start = range.upperBound
                codeStart = -1
            } else if kind != .comment, kind != .space, codeStart < 0 {
                codeStart = range.lowerBound
            }
        }
        _ = start
        if codeStart >= 0 { out.append((codeStart, chars.count)) }
        return out
    }

    /// True when the text ends inside a string, identifier or block comment (it would hang a client).
    public static func isUnterminated(_ sql: String, dialect: Dialect = .mysql) -> Bool {
        var open = false
        scan(Array(sql), dialect: dialect) { kind, _ in if kind == .unterminated { open = true } }
        return open
    }

    static func tokens(_ sql: String, dialect: Dialect = .mysql) -> [Token] {
        var out: [Token] = []
        let chars = Array(sql)
        scan(chars, dialect: dialect) { kind, range in
            let text = String(chars[range])
            switch kind {
            case .word: out.append(Token(kind: .word, text: text.uppercased()))
            case .string: out.append(Token(kind: .string, text: text))
            case .ident: out.append(Token(kind: .ident, text: text))
            case .number: out.append(Token(kind: .number, text: text))
            case .punct: out.append(Token(kind: .punct, text: text))
            default: break
            }
        }
        return out
    }

    enum Lex { case word, string, ident, punct, number, comment, space, unterminated }

    /// Calls `emit` for every lexical element, in order.
    static func scan(_ c: [Character], dialect: Dialect, _ emit: (Lex, Range<Int>) -> Void) {
        var i = 0
        let n = c.count
        func at(_ k: Int) -> Character? { k < n ? c[k] : nil }
        while i < n {
            let ch = c[i]
            let s = i
            if ch.isWhitespace {
                while i < n, c[i].isWhitespace { i += 1 }
                emit(.space, s..<i)
            } else if ch == "-", at(i + 1) == "-", dialect != .mysql || at(i + 2) == nil || isASCIISpaceOrControl(at(i + 2)!) {
                // MySQL needs "-- " with an ASCII space/control after the dashes: "--\u{A0}" is not a comment there.
                while i < n, !endsLineComment(c[i], dialect) { i += 1 }
                emit(.comment, s..<i)
            } else if ch == "#", dialect == .mysql {
                while i < n, !endsLineComment(c[i], dialect) { i += 1 }
                emit(.comment, s..<i)
            } else if ch == "/", at(i + 1) == "*" {
                i += 2
                var closed = false
                while i < n { if c[i] == "*", at(i + 1) == "/" { i += 2; closed = true; break }; i += 1 }
                emit(closed ? .comment : .unterminated, s..<i)
            } else if ch == "'" || (ch == "\"" && dialect == .mysql) {
                // MySQL escapes with backslash, and so does a Postgres E'…' string; everyone doubles the quote.
                let eString = dialect == .postgres && ch == "'" && i > 0 && (c[i - 1] == "E" || c[i - 1] == "e")
                    && (i < 2 || !(c[i - 2].isLetter || c[i - 2].isNumber || c[i - 2] == "_" || c[i - 2] == "$"))
                i += 1
                var closed = false
                while i < n {
                    if c[i] == "\\", dialect == .mysql || eString { i += 2; continue }
                    if c[i] == ch { if at(i + 1) == ch { i += 2; continue }; i += 1; closed = true; break }
                    i += 1
                }
                emit(closed ? .string : .unterminated, s..<min(i, n))
            } else if ch == "\"" || ch == "`" || (ch == "[" && dialect == .sqlite) {
                let close: Character = ch == "[" ? "]" : ch
                i += 1
                var closed = false
                while i < n { if c[i] == close { if at(i + 1) == close, close != "]" { i += 2; continue }; i += 1; closed = true; break }; i += 1 }
                emit(closed ? .ident : .unterminated, s..<i)
            } else if ch == "$", dialect == .postgres, let tagEnd = dollarTag(c, i) {
                let tag = Array(c[i...tagEnd])
                i = tagEnd + 1
                var closed = false
                while i < n {
                    if c[i] == "$", i + tag.count <= n, Array(c[i..<(i + tag.count)]) == tag { i += tag.count; closed = true; break }
                    i += 1
                }
                emit(closed ? .string : .unterminated, s..<i)
            } else if ch.isLetter || ch == "_" || (ch == "$" && dialect != .postgres) {
                while i < n, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "$" { i += 1 }
                emit(.word, s..<i)
            } else if ch.isNumber {
                while i < n, c[i].isNumber || c[i] == "." || c[i].isLetter { i += 1 }
                emit(.number, s..<i)
            } else {
                i += 1
                emit(.punct, s..<i)
            }
        }
    }

    /// " ", tab, newline and the other ASCII controls: what MySQL accepts after "--" (never Unicode spaces).
    static func isASCIISpaceOrControl(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { $0.value <= 0x20 }
    }

    /// Where a line comment ends, as the server sees it: "\n" (also inside the "\r\n" grapheme, which is one
    /// Character in Swift); psql also ends it at "\r".
    static func endsLineComment(_ ch: Character, _ dialect: Dialect) -> Bool {
        ch.unicodeScalars.contains { $0 == "\n" || (dialect == .postgres && $0 == "\r") }
    }

    /// A Character that merges an ASCII scalar with others (a quote or ";" followed by a combining mark is one
    /// grapheme in Swift but two separate bytes to the server): the lexer could misread the text. "\r\n" is fine.
    static func hasMergedASCII(_ sql: String) -> Bool {
        sql.contains { ch in ch.unicodeScalars.count > 1 && ch != "\r\n" && ch.unicodeScalars.contains { $0.isASCII } }
    }

    /// `$tag$` / `$$` at i → index of the closing `$` of the tag.
    static func dollarTag(_ c: [Character], _ i: Int) -> Int? {
        var k = i + 1
        while k < c.count, c[k].isLetter || c[k] == "_" || (k > i + 1 && c[k].isNumber) { k += 1 }
        return k < c.count && c[k] == "$" ? k : nil
    }

    // MARK: Classification

    static let readVerbs: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "WITH", "VALUES", "TABLE", "HELP", "PRAGMA"]
    static let writeWords: Set<String> = ["INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE", "UPSERT", "DROP", "CREATE", "ALTER",
                                          "TRUNCATE", "RENAME", "GRANT", "REVOKE", "INTO", "LOCK", "UNLOCK", "CALL", "DO", "HANDLER",
                                          "LOAD", "COPY", "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "ATTACH", "DETACH", "SET", "KILL",
                                          "SHUTDOWN", "FLUSH", "RESET", "PURGE", "INSTALL", "UNINSTALL", "COMMENT", "SECURITY", "NOTIFY",
                                          "LISTEN", "PREPARE", "EXECUTE", "DEALLOCATE", "IMPORT", "OUTFILE", "DUMPFILE", "PROGRAM"]
    /// Functions with side effects (or that read the server's files).
    static let unsafeFunctions: Set<String> = ["SLEEP", "BENCHMARK", "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS", "LOAD_FILE",
                                               "PG_SLEEP", "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "SET_CONFIG", "NEXTVAL", "SETVAL",
                                               "LO_IMPORT", "LO_EXPORT", "LO_UNLINK", "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_LS_DIR",
                                               "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "DBLINK", "DBLINK_EXEC", "PG_ADVISORY_LOCK",
                                               "PG_ADVISORY_XACT_LOCK", "LOAD_EXTENSION", "WRITEFILE", "READFILE", "EDIT", "FTS3_TOKENIZER",
                                               "PG_SWITCH_WAL", "PG_CREATE_RESTORE_POINT", "TXID_CURRENT", "PG_NOTIFY",
                                               "LO_CREATE", "LO_PUT", "LO_FROM_BYTEA", "PG_FILE_WRITE", "PG_FILE_UNLINK",
                                               "PG_FILE_RENAME", "PG_LOGICAL_EMIT_MESSAGE", "PG_CREATE_LOGICAL_REPLICATION_SLOT",
                                               "PG_CREATE_PHYSICAL_REPLICATION_SLOT", "PG_DROP_REPLICATION_SLOT", "PG_PROMOTE",
                                               "QUERY_TO_XML", "QUERY_TO_XMLSCHEMA", "QUERY_TO_XML_AND_XMLSCHEMA", "CURSOR_TO_XML",
                                               "PG_STAT_RESET", "PG_STAT_STATEMENTS_RESET", "PG_WAL_REPLAY_PAUSE",
                                               "PG_WAL_REPLAY_RESUME", "PG_IMPORT_SYSTEM_COLLATIONS", "MASTER_POS_WAIT",
                                               "SOURCE_POS_WAIT", "WAIT_FOR_EXECUTED_GTID_SET", "IS_FREE_LOCK", "SYS_EXEC", "SYS_EVAL"]

    /// Postgres functions (and keywords followed by "(") allowed in Elio's autonomous reads.
    static let pgSafeCalls: Set<String> = [
        // SQL syntax that takes parentheses
        "IN", "EXISTS", "AS", "OVER", "FILTER", "ANY", "ALL", "SOME", "CAST", "VALUES", "FROM", "JOIN", "ON", "USING", "WHERE",
        "AND", "OR", "NOT", "SELECT", "WITH", "LATERAL", "ROW", "ARRAY", "WITHIN", "BY", "INTERVAL", "NULLIF", "GREATEST",
        "LEAST", "EXTRACT", "POSITION", "TRIM", "SUBSTRING", "WHEN", "THEN", "ELSE", "IS", "LIKE", "ILIKE", "BETWEEN", "UNION",
        "INTERSECT", "EXCEPT", "RECURSIVE", "MATERIALIZED", "EXPLAIN", "COALESCE", "CASE", "DISTINCT", "HAVING", "GROUP", "ORDER",
        "LIMIT", "OFFSET", "VARCHAR", "NUMERIC", "DECIMAL", "CHAR", "TIMESTAMP", "TIME",
        // aggregates
        "COUNT", "SUM", "AVG", "MIN", "MAX", "ARRAY_AGG", "STRING_AGG", "JSON_AGG", "JSONB_AGG", "BOOL_AND", "BOOL_OR",
        "JSON_OBJECT_AGG", "JSONB_OBJECT_AGG", "PERCENTILE_CONT", "PERCENTILE_DISC", "ROW_NUMBER", "RANK", "DENSE_RANK",
        "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE", "NTILE",
        // strings, numbers, dates
        "LOWER", "UPPER", "LENGTH", "CHAR_LENGTH", "SUBSTR", "LEFT", "RIGHT", "CONCAT", "CONCAT_WS", "REPLACE", "SPLIT_PART",
        "LPAD", "RPAD", "LTRIM", "RTRIM", "BTRIM", "INITCAP", "MD5", "REGEXP_REPLACE", "REGEXP_MATCH", "REGEXP_MATCHES", "STRPOS",
        "FORMAT", "TO_CHAR", "TO_DATE", "TO_TIMESTAMP", "TO_NUMBER", "NOW", "CURRENT_DATE", "DATE_TRUNC", "DATE_PART", "AGE",
        "MAKE_DATE", "MAKE_INTERVAL", "ROUND", "ABS", "CEIL", "CEILING", "FLOOR", "TRUNC", "MOD", "POWER", "SQRT", "SIGN",
        "RANDOM", "GENERATE_SERIES", "UNNEST", "ARRAY_LENGTH", "CARDINALITY", "ARRAY_TO_STRING", "STRING_TO_ARRAY",
        // json
        "JSON_EXTRACT_PATH", "JSON_EXTRACT_PATH_TEXT", "JSONB_EXTRACT_PATH", "JSONB_EXTRACT_PATH_TEXT", "JSON_ARRAY_LENGTH",
        "JSONB_ARRAY_LENGTH", "JSON_BUILD_OBJECT", "JSONB_BUILD_OBJECT", "JSON_BUILD_ARRAY", "JSONB_BUILD_ARRAY", "JSONB_PRETTY",
        "JSON_TYPEOF", "JSONB_TYPEOF", "JSON_EACH", "JSONB_EACH", "JSON_OBJECT_KEYS", "JSONB_OBJECT_KEYS", "TO_JSON", "TO_JSONB",
        "ROW_TO_JSON", "JSON_ARRAY_ELEMENTS", "JSONB_ARRAY_ELEMENTS",
        // catalog helpers
        "PG_SIZE_PRETTY", "PG_TOTAL_RELATION_SIZE", "PG_RELATION_SIZE", "PG_DATABASE_SIZE", "PG_TABLE_SIZE", "PG_INDEXES_SIZE",
        "VERSION", "CURRENT_SCHEMA", "CURRENT_USER", "FORMAT_TYPE", "PG_GET_INDEXDEF", "PG_GET_CONSTRAINTDEF", "PG_GET_VIEWDEF",
        "OBJ_DESCRIPTION", "COL_DESCRIPTION",
    ]

    static func unquoteIdent(_ t: String) -> String {
        guard let q = t.first, q == "\"" || q == "`" || q == "[", t.count >= 2 else { return t }
        let inner = String(t.dropFirst().dropLast())
        return q == "[" ? inner : inner.replacingOccurrences(of: String(repeating: q, count: 2), with: String(q))
    }

    /// True only when every statement just reads: SELECT/SHOW/EXPLAIN/DESCRIBE/WITH…SELECT, no INTO, no locking
    /// reads, no writing CTEs, no side-effect functions, no client meta-commands.
    public static func isReadOnly(_ sql: String, dialect: Dialect = .mysql) -> Bool {
        if isUnterminated(sql, dialect: dialect) || hasClientCommand(sql, dialect: dialect)
            || hasExecutableComment(sql, dialect: dialect) || hasMergedASCII(sql) { return false }
        let statements = split(sql, dialect: dialect)
        guard !statements.isEmpty else { return false }
        return statements.allSatisfy { statementIsReadOnly($0, dialect: dialect) }
    }

    /// What db_query runs without asking: a read (`isReadOnly`) that is also one plain statement with nothing two
    /// parsers could read differently. No ";" but one trailing (mysql splits on it and would run the rest), no
    /// backslash (escapes depend on NO_BACKSLASH_ESCAPES / standard_conforming_strings), no "/*" comments, no
    /// control characters but tab/newline, no Unicode spaces or invisible format characters.
    public static func isAutonomousRead(_ sql: String, dialect: Dialect) -> Bool {
        guard isReadOnly(sql, dialect: dialect) else { return false }
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        if body.contains(";") || body.contains("\\") || body.contains("/*") { return false }
        for u in sql.unicodeScalars {   // the untrimmed text: trimming would drop exotic trailing spaces unseen
            if u.value < 0x20, u != "\n", u != "\t" { return false }
            if u.value == 0x7f { return false }
            if u.value > 0x7f, u.properties.isWhitespace || [.control, .format, .lineSeparator, .paragraphSeparator,
                                                               .spaceSeparator].contains(u.properties.generalCategory) { return false }
        }
        return split(body, dialect: dialect).count == 1
    }

    static func statementIsReadOnly(_ stmt: String, dialect: Dialect) -> Bool {
        let toks = tokens(stmt, dialect: dialect)
        guard let first = toks.first(where: { $0.kind == .word })?.text, readVerbs.contains(first) else { return false }
        if dialect == .postgres, !["SELECT", "WITH", "SHOW", "EXPLAIN", "VALUES", "TABLE"].contains(first) { return false }
        let words = toks.filter { $0.kind == .word }.map(\.text)
        for (k, w) in words.enumerated() {
            if writeWords.contains(w) { return false }
            if w == "FOR", k + 1 < words.count, ["UPDATE", "SHARE", "NO", "KEY"].contains(words[k + 1]) { return false }
            if w == "SHARE", k > 0, words[k - 1] == "IN" { return false }   // LOCK IN SHARE MODE
        }
        if dialect == .postgres {
            // Unicode escapes (U&"…" UESCAPE '!') can spell any name: fail closed.
            let chars = Array(stmt)
            for k in chars.indices where chars[k] == "&" && k > 0 && (chars[k - 1] == "U" || chars[k - 1] == "u")
                && k + 1 < chars.count && (chars[k + 1] == "\"" || chars[k + 1] == "'") { return false }
            if words.contains("UESCAPE") { return false }
            // "(" after anything that isn't a plain name or a listed keyword (a string, a quoted name…).
            for (k, t) in toks.enumerated() where t.text == "(" && t.kind == .punct && k > 0 {
                let prev = toks[k - 1]
                if prev.kind == .string || prev.kind == .ident { return false }
            }
        }
        // Function calls: a word or quoted identifier right before "(" (schema prefixes fall away: only the
        // last part precedes the parenthesis). Quotes stripped, case-insensitive.
        for (k, t) in toks.enumerated() where (t.kind == .word || t.kind == .ident) && k + 1 < toks.count && toks[k + 1].text == "(" {
            let name = t.kind == .word ? t.text : unquoteIdent(t.text).uppercased()
            if unsafeFunctions.contains(name) { return false }
            // Postgres: some side effects work even in a READ ONLY transaction, so only known-safe calls.
            if dialect == .postgres, !pgSafeCalls.contains(name) { return false }
        }
        // PRAGMA x = y (or PRAGMA x(y)) changes settings.
        if first == "PRAGMA", toks.contains(where: { $0.text == "=" || $0.text == "(" }) { return false }
        // EXPLAIN ANALYZE runs the statement: fine only for reads, already checked above.
        return true
    }

    /// MySQL/MariaDB run the content of `/*! … */`, `/*!50001 … */` and `/*M! … */`: never read-only.
    public static func hasExecutableComment(_ sql: String, dialect: Dialect) -> Bool {
        let chars = Array(sql)
        var found = false
        scan(chars, dialect: dialect) { kind, range in
            guard kind == .comment || kind == .unterminated, range.count >= 3, chars[range.lowerBound] == "/" else { return }
            let head = String(chars[range.lowerBound..<min(range.upperBound, range.lowerBound + 4)])
            if head.hasPrefix("/*!") || head.hasPrefix("/*M!") || head.hasPrefix("/*m!") { found = true }
        }
        return found
    }

    /// psql backslash commands (\! runs a shell), sqlite3 dot-commands, mysql `\` commands outside literals.
    public static func hasClientCommand(_ sql: String, dialect: Dialect) -> Bool {
        // psql parses meta-commands with its own lexer (which also depends on server settings): any backslash
        // at all is refused, so no literal can be read differently by psql and by this lexer.
        if dialect == .postgres { return sql.contains("\\") }
        let chars = Array(sql)
        var found = false
        var atStatementStart = true, atLineStart = true
        scan(chars, dialect: dialect) { kind, range in
            switch kind {
            case .punct:
                let ch = chars[range.lowerBound]
                if ch == "\\" { found = true }
                if ch == ".", dialect == .sqlite, atStatementStart || atLineStart { found = true }
                atStatementStart = ch == ";"
                atLineStart = false
            case .space:
                if chars[range].contains(where: \.isNewline) { atLineStart = true }
            case .comment: break
            case .word:
                // mysql's named client commands (system, source, connect…) only count as a statement's first word.
                if dialect == .mysql, atStatementStart, mysqlClientCommands.contains(String(chars[range]).uppercased()) { found = true }
                atStatementStart = false
                atLineStart = false
            default:
                atStatementStart = false
                atLineStart = false
            }
        }
        return found
    }

    static let mysqlClientCommands: Set<String> = ["SYSTEM", "SOURCE", "CONNECT", "TEE", "NOTEE", "PAGER", "NOPAGER", "EDIT", "EGO",
                                                   "PROMPT", "REHASH", "WARNINGS", "NOWARNING", "DELIMITER", "CHARSET", "QUIT",
                                                   "EXIT", "GO", "PRINT", "STATUS", "RESETCONNECTION", "QUERY_ATTRIBUTES",
                                                   "SSL_SESSION_DATA_PRINT", "HELP"]

    /// Statements that destroy data or structure (confirmation needed even outside production):
    /// DROP, TRUNCATE, ALTER, RENAME, DELETE/UPDATE without WHERE. Returns a short Italian reason.
    public static func destructiveReason(_ stmt: String, dialect: Dialect = .mysql) -> String? {
        let words = tokens(stmt, dialect: dialect).filter { $0.kind == .word }.map(\.text)
        guard let first = words.first else { return nil }
        // WITH … DELETE: look at the verb after the CTEs too.
        let verb = first == "WITH" ? (words.first { ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE"].contains($0) } ?? first) : first
        switch verb {
        case "DROP": return "DROP elimina \(words.count > 1 ? words[1].lowercased() : "l'oggetto") e i suoi dati"
        case "TRUNCATE": return "TRUNCATE svuota la tabella"
        case "ALTER": return "ALTER cambia la struttura"
        case "RENAME": return "RENAME rinomina una tabella"
        case "DELETE" where !words.contains("WHERE"): return "DELETE senza WHERE cancella tutte le righe"
        case "UPDATE" where !words.contains("WHERE"): return "UPDATE senza WHERE modifica tutte le righe"
        case "FLUSHALL", "FLUSHDB": return "\(verb) cancella tutte le chiavi"
        default: return nil
        }
    }

    /// The statement produces a result set (SELECT-like, or anything with RETURNING).
    public static func returnsRows(_ stmt: String, dialect: Dialect = .mysql) -> Bool {
        let words = tokens(stmt, dialect: dialect).filter { $0.kind == .word }.map(\.text)
        guard let first = words.first else { return false }
        if ["SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "VALUES", "TABLE", "PRAGMA", "HELP", "CHECK", "ANALYZE",
            "OPTIMIZE", "REPAIR", "CHECKSUM", "CALL"].contains(first) { return !words.contains("INTO") || first != "SELECT" }
        if first == "WITH" { return true }
        return words.contains("RETURNING")
    }

    /// Adds `LIMIT n` to a plain SELECT that has none, so a huge table never floods the client.
    public static func withLimit(_ stmt: String, _ n: Int, dialect: Dialect = .mysql) -> String {
        let toks = tokens(stmt, dialect: dialect)
        let words = toks.filter { $0.kind == .word }.map(\.text)
        guard let first = words.first, first == "SELECT" || (first == "WITH" && words.contains("SELECT")),
              !words.contains("LIMIT"), !words.contains("INTO"), !words.contains("FETCH"), !words.contains("OFFSET"),
              !words.contains("FOR"), !words.contains("PROCEDURE"),
              !words.contains(where: { ["INSERT", "UPDATE", "DELETE"].contains($0) }) else { return stmt }
        // Aggregates without GROUP BY return one row anyway; a LIMIT doesn't hurt.
        var s = stmt.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s.removeLast() }
        // A trailing line comment would swallow the LIMIT.
        return s + "\nLIMIT \(n)"
    }

    /// Quotes an identifier for the dialect.
    public static func quoteIdent(_ name: String, dialect: Dialect) -> String {
        switch dialect {
        case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// Quotes a string literal for the dialect.
    public static func quoteLiteral(_ value: String, dialect: Dialect) -> String {
        var v = value.replacingOccurrences(of: "'", with: "''")
        if dialect == .mysql { v = v.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + v + "'"
    }
}

/// Read-only shell commands Elio may run on a server without asking. Deny by default and deliberately simple:
/// a short list of commands, each with its boolean letters, its valued flags (standalone token + value, or a
/// purely numeric attached value like -n100) and a maximum of positional arguments. Shell metacharacters are
/// refused; anything unexpected → not read-only, so it goes through the confirmation gate.
public enum ShellCommandClassifier {
    struct Spec {
        var short: Set<Character> = []
        var valued: Set<String> = []
        var long: Set<String> = []
        var maxPositional = 0
        var numericFlag = false
    }

    static let specs: [String: Spec] = [
        "ls": Spec(short: Set("lahtrRSd1AFHn"), maxPositional: 10),
        "cat": Spec(short: Set("n"), maxPositional: 10),
        "head": Spec(valued: ["-n", "-c"], maxPositional: 10, numericFlag: true),
        "tail": Spec(valued: ["-n", "-c"], maxPositional: 10, numericFlag: true),
        "wc": Spec(short: Set("lwc"), maxPositional: 10),
        "df": Spec(short: Set("hkTi"), maxPositional: 5),
        "du": Spec(short: Set("shc"), valued: ["-d"], maxPositional: 10),
        "pwd": Spec(),
        "whoami": Spec(),
        "uptime": Spec(),
        "ps": Spec(short: Set("auxefwl"), maxPositional: 1),
        "free": Spec(short: Set("hmg")),
        "uname": Spec(short: Set("asnrm")),
        "id": Spec(maxPositional: 1),
        "stat": Spec(maxPositional: 10),
        "file": Spec(maxPositional: 10),
        "grep": Spec(short: Set("inv lcwxEFHhoIr".replacingOccurrences(of: " ", with: "")), valued: ["-e", "-m", "-A", "-B", "-C"], maxPositional: 10),
    ]

    static let gitSpecs: [String: Spec] = [
        "status": Spec(short: Set("sb"), long: ["--short", "--branch", "--porcelain"], maxPositional: 5),
        "log": Spec(valued: ["-n"], long: ["--oneline", "--stat", "--name-only", "--name-status", "--no-merges", "--graph", "--decorate"],
                    maxPositional: 5, numericFlag: true),
        "diff": Spec(long: ["--stat", "--name-only", "--name-status", "--cached", "--staged"], maxPositional: 5),
        "show": Spec(long: ["--stat", "--name-only", "--name-status", "--oneline"], maxPositional: 3),
        "branch": Spec(short: Set("arv"), long: ["--list", "--show-current"]),
    ]

    static let findValued: Set<String> = ["-name", "-iname", "-type", "-maxdepth", "-mindepth", "-mtime", "-size", "-path"]

    public static func isReadOnly(_ command: String) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, let segments = splitSegments(cmd), !segments.isEmpty else { return false }
        return segments.allSatisfy(segmentIsReadOnly)
    }

    /// Local system queries that only read (network addresses, listening ports, versions) plus `cd`, possibly
    /// chained with `;` / `&&` / `|`: an agent asking to run these outside the sandbox doesn't need the user.
    /// Every chained part must pass on its own; anything that expands, redirects or isn't listed doesn't.
    public static func isLocalReadOnly(_ command: String) -> Bool {
        guard let parts = splitChain(command), !parts.isEmpty else { return false }
        for part in parts {
            guard let segments = splitSegments(part), !segments.isEmpty else { return false }
            for (index, var words) in segments.enumerated() {
                if let p = words.first, ["/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/"].contains(where: { p.hasPrefix($0) }) {
                    words[0] = (p as NSString).lastPathComponent
                }
                // Only system queries here, not the file-reading list: outside the sandbox its read protections
                // (~/.ssh, keys, tokens) don't apply, and git would run the repo's config (fsmonitor, signing…).
                guard localQuery(words) || (["pwd", "whoami", "uptime", "uname", "df", "ps"].contains(words[0]) && segmentIsReadOnly(words))
                        || (index > 0 && filtersStdinOnly(words)) else { return false }
            }
        }
        return true
    }

    /// Splits on `;` and `&&` outside quotes (no `||`, no `&` background, no newlines).
    static func splitChain(_ cmd: String) -> [String]? {
        var parts: [String] = [], cur = ""
        var quote: Character? = nil
        let c = Array(cmd)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if let q = quote { cur.append(ch); if ch == q { quote = nil }; i += 1; continue }
            if ch == "'" || ch == "\"" { quote = ch; cur.append(ch); i += 1; continue }
            if ch == ";" { parts.append(cur); cur = ""; i += 1; continue }
            if ch == "&" {
                guard i + 1 < c.count, c[i + 1] == "&" else { return nil }
                parts.append(cur); cur = ""; i += 2; continue
            }
            cur.append(ch); i += 1
        }
        guard quote == nil else { return nil }
        parts.append(cur)
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        return trimmed.contains(where: \.isEmpty) ? nil : trimmed
    }

    /// After a pipe: head/tail/wc/grep reading only what's piped in (no file arguments).
    static func filtersStdinOnly(_ words: [String]) -> Bool {
        guard let name = words.first, segmentIsReadOnly(words) else { return false }
        let positional = words.dropFirst().filter { !$0.hasPrefix("-") && $0.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil }
        switch name {
        case "head", "tail", "wc": return positional.isEmpty
        case "grep": return positional.count == 1   // the pattern
        default: return false
        }
    }

    static func localQuery(_ words: [String]) -> Bool {
        guard let name = words.first else { return false }
        let args = Array(words.dropFirst())
        let plain = args.allSatisfy { $0.range(of: #"^[A-Za-z0-9:@._,/+-]+$"#, options: .regularExpression) != nil }
        guard plain else { return false }
        switch name {
        case "cd": return args.count <= 1 && !(args.first?.hasPrefix("-") ?? false)
        case "echo": return !(args.first?.hasPrefix("-") ?? false) && args.count <= 20
        case "sw_vers", "hostname", "whoami", "uptime", "arch", "date": return args.isEmpty
        case "which": return args.count <= 5 && !args.contains { $0.hasPrefix("-") && $0 != "-a" }
        case "ipconfig":
            guard let sub = args.first else { return false }
            return ["getifaddr", "getoption", "ifcount", "getsummary"].contains(sub) && args.count <= 3
        case "ifconfig": return args.count <= 1 && !args.contains { $0.hasPrefix("-") && $0 != "-a" && $0 != "-l" }
        case "lsof":
            // Only options (it reads the kernel's tables): -i / -n / -P / -s TCP:LISTEN / -iTCP:80 …, never +flags or files.
            return !args.isEmpty && args.allSatisfy { $0.hasPrefix("-") || $0.range(of: #"^[A-Z]+:[A-Z]+$"#, options: .regularExpression) != nil }
                && !args.contains { $0.hasPrefix("-F") || $0.hasPrefix("-r") || $0.hasPrefix("+") }
        case "netstat": return args.allSatisfy { $0.hasPrefix("-") && $0.dropFirst().allSatisfy { "anrlvWfp46".contains($0) } || ["inet", "inet6", "tcp", "udp"].contains($0) }
        case "scutil": return args.count >= 1 && ["--dns", "--proxy", "--nwi"].contains(args[0]) && args.count == 1
            || (args.count == 2 && args[0] == "--get" && ["ComputerName", "LocalHostName", "HostName"].contains(args[1]))
        case "system_profiler": return args.allSatisfy { !$0.hasPrefix("-") || $0 == "-json" || $0 == "-detailLevel" || ["mini", "basic"].contains($0) } && args.count <= 4
        default: return false
        }
    }

    /// Words of each `|`-separated command. nil when anything could expand, redirect, chain or run in background.
    static func splitSegments(_ cmd: String) -> [[String]]? {
        var segments: [[String]] = [], words: [String] = [], word = ""
        var quote: Character? = nil, inWord = false
        let c = Array(cmd)
        var i = 0
        func endWord() { if inWord { words.append(word); word = ""; inWord = false } }
        while i < c.count {
            let ch = c[i]
            if quote == "'" {
                if ch == "'" { quote = nil } else { word.append(ch) }
                i += 1; continue
            }
            // Expansions work outside quotes and inside double quotes: refuse them.
            if "$`\\!\n\r".contains(ch) { return nil }
            if quote == "\"" {
                if ch == "\"" { quote = nil } else { word.append(ch) }
                i += 1; continue
            }
            switch ch {
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t": endWord()
            case "|":
                if i + 1 < c.count, c[i + 1] == "|" { return nil }
                endWord()
                guard !words.isEmpty else { return nil }
                segments.append(words); words = []
            case "<", ">", "&", ";", "(", ")", "{", "}": return nil
            // Globs expand remotely into file names, which may look like options ("-exec", "--output=x").
            case "*", "?", "[", "]", "~": return nil
            case "#" where !inWord: return nil
            default: word.append(ch); inWord = true
            }
            i += 1
        }
        if quote != nil { return nil }
        endWord()
        guard !words.isEmpty else { return nil }
        segments.append(words)
        return segments
    }

    static func segmentIsReadOnly(_ words: [String]) -> Bool {
        guard let name = words.first else { return false }
        let args = Array(words.dropFirst())
        if name == "find" { return findIsReadOnly(args) }
        if name == "git" {
            guard let sub = args.first, let spec = gitSpecs[sub] else { return false }
            return argsAllowed(Array(args.dropFirst()), spec)
        }
        guard let spec = specs[name] else { return false }
        return argsAllowed(args, spec)
    }

    static func argsAllowed(_ args: [String], _ spec: Spec) -> Bool {
        var positional = 0
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                guard spec.long.contains(a) else { return false }          // no "=value" forms at all
            } else if a.hasPrefix("-"), a.count > 1 {
                let body = a.dropFirst()
                if spec.valued.contains(a) {
                    i += 1
                    guard i < args.count, !args[i].hasPrefix("-") || args[i].dropFirst().allSatisfy(\.isNumber) else { return false }
                } else if spec.numericFlag, body.allSatisfy(\.isNumber) {
                    // -100
                } else if let f = body.first, spec.valued.contains("-\(f)"), body.count > 1, body.dropFirst().allSatisfy(\.isNumber) {
                    // -n100: only a purely numeric attached value
                } else if !body.allSatisfy({ spec.short.contains($0) }) {
                    return false
                }
            } else {
                positional += 1
            }
            i += 1
        }
        return positional <= spec.maxPositional
    }

    static func findIsReadOnly(_ args: [String]) -> Bool {
        var i = 0, paths = 0
        while i < args.count {
            let a = args[i]
            if findValued.contains(a) {
                guard i + 1 < args.count else { return false }
                i += 2
                continue
            }
            if a.hasPrefix("-") || a == "!" || a == "(" || a == ")" { return false }
            guard i == paths else { return false }   // paths only before the expression
            paths += 1
            i += 1
        }
        return paths <= 5
    }
}
