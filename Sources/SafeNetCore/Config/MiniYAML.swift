import Foundation

// A deliberately small YAML subset, just enough for config.yaml (no external dependency):
//   - block maps (2-space indentation recommended; any consistent indentation parses)
//   - block lists of scalars and of maps ("- key: v" with following keys aligned)
//   - lists may sit at the same indentation as their parent key
//   - scalars: plain, "double-quoted" (\\ \" \n \t escapes), 'single-quoted' ('' escape),
//     numbers, true/false, null/~
//   - flow forms: [] , {} and simple one-line [a, b, "c"] lists of scalars
//   - '#' comments (full-line, or after whitespace outside quotes)
// Not supported (throws or is treated as plain text): anchors, tags, multi-line scalars,
// block scalars (| >), nested flow collections, tabs for indentation, documents (---).

public struct YAMLError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let message: String
    public var description: String { "YAML error at line \(line): \(message)" }
}

public struct YAMLEntry: Equatable {
    public var key: String
    public var value: YAMLValue
    public init(_ key: String, _ value: YAMLValue) { self.key = key; self.value = value }
}

public indirect enum YAMLValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([YAMLValue])
    case map([YAMLEntry])

    public subscript(key: String) -> YAMLValue? {
        if case .map(let entries) = self { return entries.first { $0.key == key }?.value }
        return nil
    }
    public var listValue: [YAMLValue]? { if case .list(let l) = self { return l }; return nil }
    public var mapEntries: [YAMLEntry]? { if case .map(let m) = self { return m }; return nil }
}

public enum MiniYAML {
    // MARK: Parsing

    private struct Line { var indent: Int; var text: String; var no: Int }

    public static func parse(_ text: String) throws -> YAMLValue {
        var lines: [Line] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            var r = raw
            if r.hasSuffix("\r") { r.removeLast() }
            let stripped = stripComment(r)
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "---" && lines.isEmpty { continue }
            var indent = 0
            for ch in stripped {
                if ch == " " { indent += 1 }
                else if ch == "\t" { throw YAMLError(line: i + 1, message: "tab in indentation") }
                else { break }
            }
            lines.append(Line(indent: indent, text: trimmed, no: i + 1))
        }
        if lines.isEmpty { return .map([]) }
        var pos = 0
        let v = try parseBlock(&lines, &pos, indent: lines[0].indent)
        if pos < lines.count { throw YAMLError(line: lines[pos].no, message: "unexpected indentation") }
        return v
    }

    /// Removes a trailing comment (a '#' at line start or preceded by whitespace, outside quotes).
    private static func stripComment(_ s: String) -> String {
        var inS = false, inD = false
        var prev: Character = " "
        var escaped = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let ch = s[idx]
            if inD {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inD = false }
            } else if inS {
                if ch == "'" { inS = false }
            } else if ch == "#" && (prev == " " || prev == "\t" || idx == s.startIndex) {
                return String(s[s.startIndex..<idx])
            } else if ch == "\"" && (prev == " " || prev == ":" || prev == "-" || prev == "[" || prev == ",") {
                inD = true
            } else if ch == "'" && (prev == " " || prev == ":" || prev == "-" || prev == "[" || prev == ",") {
                inS = true
            }
            prev = ch
            idx = s.index(after: idx)
        }
        return s
    }

    private static func isListItem(_ t: String) -> Bool { t == "-" || t.hasPrefix("- ") }

    private static func parseBlock(_ lines: inout [Line], _ pos: inout Int, indent: Int) throws -> YAMLValue {
        isListItem(lines[pos].text) ? try parseList(&lines, &pos, indent: indent)
                                    : try parseMap(&lines, &pos, indent: indent)
    }

    /// Finds the index of the ':' that separates key from value, or nil if `s` is not "key: ...".
    private static func keyColon(_ s: String) -> String.Index? {
        var idx = s.startIndex
        if let q = s.first, q == "\"" || q == "'" {
            // skip the quoted key
            idx = s.index(after: idx)
            var escaped = false
            while idx < s.endIndex {
                let ch = s[idx]
                if q == "\"" {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { idx = s.index(after: idx); break }
                } else if ch == "'" {
                    let n = s.index(after: idx)
                    if n < s.endIndex && s[n] == "'" { idx = n } else { idx = n; break }
                }
                idx = s.index(after: idx)
            }
            guard idx <= s.endIndex, idx < s.endIndex, s[idx] == ":" else { return nil }
            let n = s.index(after: idx)
            return (n == s.endIndex || s[n] == " ") ? idx : nil
        }
        if let f = s.first, f == "[" || f == "{" { return nil }
        while idx < s.endIndex {
            if s[idx] == ":" {
                let n = s.index(after: idx)
                if n == s.endIndex || s[n] == " " { return idx }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func parseMap(_ lines: inout [Line], _ pos: inout Int, indent: Int) throws -> YAMLValue {
        var entries: [YAMLEntry] = []
        while pos < lines.count, lines[pos].indent == indent, !isListItem(lines[pos].text) {
            let ln = lines[pos]
            guard let c = keyColon(ln.text) else {
                throw YAMLError(line: ln.no, message: "expected 'key: value'")
            }
            let keyText = String(ln.text[ln.text.startIndex..<c])
            let key = try parseScalarString(keyText, line: ln.no)
            if entries.contains(where: { $0.key == key }) {
                throw YAMLError(line: ln.no, message: "duplicate key '\(key)'")
            }
            let rest = String(ln.text[ln.text.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            pos += 1
            if rest.isEmpty {
                if pos < lines.count, lines[pos].indent > indent {
                    entries.append(YAMLEntry(key, try parseBlock(&lines, &pos, indent: lines[pos].indent)))
                } else if pos < lines.count, lines[pos].indent == indent, isListItem(lines[pos].text) {
                    entries.append(YAMLEntry(key, try parseList(&lines, &pos, indent: indent)))
                } else {
                    entries.append(YAMLEntry(key, .null))
                }
            } else {
                entries.append(YAMLEntry(key, try parseInline(rest, line: ln.no)))
            }
        }
        if pos < lines.count, lines[pos].indent > indent {
            throw YAMLError(line: lines[pos].no, message: "unexpected indentation")
        }
        if pos < lines.count, lines[pos].indent == indent, isListItem(lines[pos].text) {
            throw YAMLError(line: lines[pos].no, message: "list item where a key was expected")
        }
        return .map(entries)
    }

    private static func parseList(_ lines: inout [Line], _ pos: inout Int, indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while pos < lines.count, lines[pos].indent == indent, isListItem(lines[pos].text) {
            let ln = lines[pos]
            let afterDash = ln.text.dropFirst(1)
            let spaces = afterDash.prefix { $0 == " " }.count
            let rest = String(afterDash.dropFirst(spaces))
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent {
                    items.append(try parseBlock(&lines, &pos, indent: lines[pos].indent))
                } else {
                    items.append(.null)
                }
            } else if keyColon(rest) != nil {
                // "- key: value": reinterpret this line as a map line indented past the dash.
                let newIndent = indent + 1 + spaces
                lines[pos] = Line(indent: newIndent, text: rest, no: ln.no)
                items.append(try parseMap(&lines, &pos, indent: newIndent))
            } else {
                pos += 1
                items.append(try parseInline(rest, line: ln.no))
            }
        }
        if pos < lines.count, lines[pos].indent > indent {
            throw YAMLError(line: lines[pos].no, message: "unexpected indentation")
        }
        return .list(items)
    }

    private static func parseInline(_ s: String, line: Int) throws -> YAMLValue {
        if s == "[]" { return .list([]) }
        if s == "{}" { return .map([]) }
        if s.hasPrefix("[") {
            guard s.hasSuffix("]") else { throw YAMLError(line: line, message: "unterminated flow list") }
            let inner = String(s.dropFirst().dropLast())
            return .list(try splitFlow(inner, line: line).map { try parseScalar($0, line: line) })
        }
        if s.hasPrefix("{") { throw YAMLError(line: line, message: "flow maps are not supported") }
        return try parseScalar(s, line: line)
    }

    private static func splitFlow(_ s: String, line: Int) throws -> [String] {
        var parts: [String] = [], cur = ""
        var inS = false, inD = false, escaped = false
        for ch in s {
            if inD {
                cur.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inD = false }
            } else if inS {
                cur.append(ch)
                if ch == "'" { inS = false }
            } else if ch == "," {
                parts.append(cur); cur = ""
            } else {
                if ch == "\"" && cur.trimmingCharacters(in: .whitespaces).isEmpty { inD = true }
                if ch == "'" && cur.trimmingCharacters(in: .whitespaces).isEmpty { inS = true }
                if ch == "[" || ch == "]" || ch == "{" || ch == "}" {
                    throw YAMLError(line: line, message: "nested flow collections are not supported")
                }
                cur.append(ch)
            }
        }
        if inD || inS { throw YAMLError(line: line, message: "unterminated quoted string") }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty || !parts.isEmpty { parts.append(cur) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseScalar(_ s: String, line: Int) throws -> YAMLValue {
        if let f = s.first, f == "\"" || f == "'" { return .string(try parseScalarString(s, line: line)) }
        switch s {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null", "~": return .null
        default: break
        }
        if let d = Double(s), d.isFinite, s.allSatisfy({ "0123456789+-.eE".contains($0) }) { return .number(d) }
        return .string(s)
    }

    /// Parses a plain or quoted string (used for keys and quoted values).
    private static func parseScalarString(_ s: String, line: Int) throws -> String {
        guard let q = s.first, q == "\"" || q == "'" else { return s }
        var out = ""
        let chars = Array(s.dropFirst())
        var i = 0
        var closed = false
        while i < chars.count {
            let ch = chars[i]
            if q == "\"" {
                if ch == "\\" {
                    i += 1
                    guard i < chars.count else { break }
                    switch chars[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    default: throw YAMLError(line: line, message: "unsupported escape \\\(chars[i])")
                    }
                } else if ch == "\"" { closed = true; i += 1; break }
                else { out.append(ch) }
            } else {
                if ch == "'" {
                    if i + 1 < chars.count && chars[i + 1] == "'" { out.append("'"); i += 1 }
                    else { closed = true; i += 1; break }
                } else { out.append(ch) }
            }
            i += 1
        }
        if !closed { throw YAMLError(line: line, message: "unterminated quoted string") }
        if i < chars.count { throw YAMLError(line: line, message: "unexpected text after quoted string") }
        return out
    }

    // MARK: Emitting

    /// Emits `value` (normally a map). `comments` maps a dotted key path (e.g. "grace" or
    /// "allow.ips"; list contents are not addressed) to comment lines written above that key.
    public static func emit(_ value: YAMLValue, comments: [String: [String]] = [:]) -> String {
        var out = ""
        emitNode(value, indent: 0, path: "", comments: comments, into: &out)
        return out
    }

    private static func pad(_ n: Int) -> String { String(repeating: " ", count: n) }

    private static func emitNode(_ v: YAMLValue, indent: Int, path: String, comments: [String: [String]], into out: inout String) {
        guard case .map(let entries) = v else { return }
        for e in entries {
            let p = path.isEmpty ? e.key : path + "." + e.key
            for c in comments[p] ?? [] { out += pad(indent) + c + "\n" }
            let k = formatKey(e.key)
            switch e.value {
            case .map(let m) where !m.isEmpty:
                out += pad(indent) + k + ":\n"
                emitNode(e.value, indent: indent + 2, path: p, comments: comments, into: &out)
            case .list(let l) where !l.isEmpty:
                out += pad(indent) + k + ":\n"
                emitList(l, indent: indent + 2, into: &out)
            default:
                out += pad(indent) + k + ": " + formatInline(e.value) + "\n"
            }
        }
    }

    private static func emitList(_ items: [YAMLValue], indent: Int, into out: inout String) {
        for item in items {
            switch item {
            case .map(let m) where !m.isEmpty:
                var sub = ""
                emitNode(item, indent: indent + 2, path: "\u{0}", comments: [:], into: &sub)
                // replace the first line's indentation with "- "
                let prefix = pad(indent + 2)
                if sub.hasPrefix(prefix) { sub = pad(indent) + "- " + sub.dropFirst(prefix.count) }
                out += sub
            case .list(let l) where !l.isEmpty:
                // nested lists are outside the supported subset; flatten to flow form
                out += pad(indent) + "- [" + l.map(formatInline).joined(separator: ", ") + "]\n"
            default:
                out += pad(indent) + "- " + formatInline(item) + "\n"
            }
        }
    }

    private static func formatKey(_ k: String) -> String { needsQuoting(k) ? quote(k) : k }

    private static func formatInline(_ v: YAMLValue) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .string(let s): return needsQuoting(s) ? quote(s) : s
        case .list(let l): return l.isEmpty ? "[]" : "[" + l.map(formatInline).joined(separator: ", ") + "]"
        case .map(let m): return m.isEmpty ? "{}" : "{}"
        }
    }

    private static func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s != s.trimmingCharacters(in: .whitespaces) { return true }
        if let f = s.first, "-?:,[]{}#&*!|>'\"%@`~".contains(f) { return true }
        if s.contains(": ") || s.hasSuffix(":") || s.contains(" #") || s.contains("\n") || s.contains("\t")
            || s.contains("\"") || s.contains("\\") { return true }
        let lower = s.lowercased()
        if ["true", "false", "null", "yes", "no", "on", "off", "y", "n"].contains(lower) { return true }
        if Double(s) != nil { return true }
        return false
    }

    private static func quote(_ s: String) -> String {
        var o = "\""
        for ch in s {
            switch ch {
            case "\\": o += "\\\\"
            case "\"": o += "\\\""
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            case "\r": o += "\\r"
            default: o.append(ch)
            }
        }
        return o + "\""
    }

    // MARK: Comment preservation (best effort)

    /// Collects full-line comment blocks that sit directly above top-level/nested *map keys*,
    /// keyed by dotted path. Keys inside lists and trailing comments are not preserved.
    public static func extractComments(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var pending: [String] = []
        var stack: [(indent: Int, key: String?)] = []   // key nil = list item scope
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { pending.append(trimmed); continue }
            let indent = raw.prefix { $0 == " " }.count
            while let top = stack.last, top.indent >= indent { stack.removeLast() }
            let code = stripComment(trimmed)
            if isListItem(code) {
                stack.append((indent, nil))
                pending = []
                continue
            }
            if stack.contains(where: { $0.key == nil }) { pending = []; continue }
            guard let c = keyColon(code) else { pending = []; continue }
            guard let key = try? parseScalarString(String(code[code.startIndex..<c]), line: 0) else { pending = []; continue }
            let path = (stack.compactMap { $0.key } + [key]).joined(separator: ".")
            if !pending.isEmpty { result[path] = pending; pending = [] }
            stack.append((indent, key))
        }
        return result
    }
}
