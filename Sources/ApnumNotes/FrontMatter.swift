import Foundation

/// Reads and writes the note file format: a small `key: value` header between
/// `---` lines, then the Markdown body, kept exactly as written.
enum NoteFile {
    struct ParseError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Serialize

    static func serialize(_ note: Note) -> String {
        var out = "---\n"
        out += "id: \(note.id.uuidString)\n"
        out += "title: \(quote(note.title))\n"
        out += "tags: [\(note.tags.map(quote).joined(separator: ", "))]\n"
        out += "pinned: \(note.pinned)\n"
        out += "created: \(formatDate(note.createdAt))\n"
        out += "updated: \(formatDate(note.updatedAt))\n"
        if let d = note.deletedAt { out += "deleted: \(formatDate(d))\n" }
        out += "---\n"
        out += note.body
        return out
    }

    private static let special = Set("\":#,[]{}'\\&*!|>%@`".unicodeScalars)

    private static func isControl(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || u.value == 0x7F || u.value == 0x2028 || u.value == 0x2029
    }

    /// Plain when safe, otherwise double-quoted with escapes.
    static func quote(_ s: String) -> String {
        let needs = s.isEmpty
            || s != s.trimmingCharacters(in: .whitespaces)
            || s.unicodeScalars.contains { special.contains($0) || isControl($0) }
            || s.hasPrefix("-") || s.hasPrefix("?")
        guard needs else { return s }
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if isControl(u) { out += "\\u{" + String(u.value, radix: 16) + "}" } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func formatDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        let whole = d.timeIntervalSince1970 == d.timeIntervalSince1970.rounded(.down)
        f.formatOptions = whole ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: Parse

    static func parse(_ text: String) throws -> Note {
        let bytes = Array(text.utf8)
        var pos = 0
        func nextLine() -> String? {
            guard pos < bytes.count else { return nil }
            var end = pos
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            var lineEnd = end
            if lineEnd > pos && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let line = String(decoding: bytes[pos..<lineEnd], as: UTF8.self)
            pos = min(end + 1, bytes.count)
            return line
        }
        guard var first = nextLine() else { throw ParseError("empty file") }
        if first.hasPrefix("\u{FEFF}") { first.removeFirst() }
        guard first == "---" else { throw ParseError("missing opening --- line") }

        var fields: [String: String] = [:]
        var closed = false
        while let line = nextLine() {
            if line == "---" { closed = true; break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { throw ParseError("bad header line: \(line.prefix(40))") }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard closed else { throw ParseError("missing closing --- line") }
        let body = String(decoding: bytes[pos...], as: UTF8.self)

        guard let idRaw = fields["id"], let id = UUID(uuidString: try scalar(idRaw)) else { throw ParseError("missing or invalid id") }
        func date(_ key: String) throws -> Date? {
            guard let raw = fields[key] else { return nil }
            guard let d = parseDate(try scalar(raw)) else { throw ParseError("invalid \(key) date") }
            return d
        }
        guard let created = try date("created") else { throw ParseError("missing created") }
        let updated = try date("updated") ?? created
        let pinnedRaw = try fields["pinned"].map(scalar) ?? "false"
        guard pinnedRaw == "true" || pinnedRaw == "false" else { throw ParseError("invalid pinned value") }
        return Note(
            id: id, title: try fields["title"].map(scalar) ?? "", body: body,
            tags: try fields["tags"].map(list) ?? [], pinned: pinnedRaw == "true",
            createdAt: created, updatedAt: updated, deletedAt: try date("deleted"))
    }

    /// Reads one value from `s` starting at `i`: quoted (with escapes) or plain up to a stop character.
    private static func readValue(_ s: [Unicode.Scalar], _ i: inout Int, stops: Set<Unicode.Scalar>) throws -> String {
        while i < s.count, s[i] == " " { i += 1 }
        var out = String.UnicodeScalarView()
        if i < s.count, s[i] == "\"" {
            i += 1
            while i < s.count {
                let u = s[i]
                i += 1
                if u == "\"" { return String(out) }
                guard u == "\\" else { out.append(u); continue }
                guard i < s.count else { break }
                let e = s[i]
                i += 1
                switch e {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "u":
                    guard i < s.count, s[i] == "{" else { throw ParseError("bad \\u escape") }
                    i += 1
                    var hex = ""
                    while i < s.count, s[i] != "}" { hex.unicodeScalars.append(s[i]); i += 1 }
                    i += 1
                    guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else { throw ParseError("bad \\u escape") }
                    out.append(sc)
                default: throw ParseError("unknown escape \\\(e)")
                }
            }
            throw ParseError("unterminated quoted string")
        }
        while i < s.count, !stops.contains(s[i]) { out.append(s[i]); i += 1 }
        return String(out).trimmingCharacters(in: .whitespaces)
    }

    private static func requireEnd(_ s: [Unicode.Scalar], _ i: Int) throws {
        var rest = String.UnicodeScalarView(s[i...]).description.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("#") { rest = "" }
        if !rest.isEmpty { throw ParseError("unexpected text after value") }
    }

    static func scalar(_ raw: String) throws -> String {
        let s = Array(raw.unicodeScalars)
        var i = 0
        let v = try readValue(s, &i, stops: ["#"])
        try requireEnd(s, i)
        return v
    }

    static func list(_ raw: String) throws -> [String] {
        let s = Array(raw.unicodeScalars)
        var i = 0
        while i < s.count, s[i] == " " { i += 1 }
        guard i < s.count, s[i] == "[" else { throw ParseError("tags must be a [list]") }
        i += 1
        var items: [String] = []
        while true {
            while i < s.count, s[i] == " " { i += 1 }
            guard i < s.count else { throw ParseError("unterminated tag list") }
            if s[i] == "]" { i += 1; break }
            items.append(try readValue(s, &i, stops: [",", "]"]))
            while i < s.count, s[i] == " " { i += 1 }
            guard i < s.count else { throw ParseError("unterminated tag list") }
            if s[i] == "," { i += 1 } else if s[i] != "]" { throw ParseError("bad tag list") }
        }
        try requireEnd(s, i)
        return items
    }
}
