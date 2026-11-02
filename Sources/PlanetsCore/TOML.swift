import Foundation

public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var table: [String: TOMLValue]? { if case .table(let v) = self { v } else { nil } }
    public var array: [TOMLValue]? { if case .array(let v) = self { v } else { nil } }
    public var double: Double? {
        switch self {
        case .float(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }
    public var int: Int? {
        switch self {
        case .integer(let v): v
        case .float(let v): Int(exactly: v)
        default: nil
        }
    }
    public var strings: [String]? { array?.compactMap(\.string) }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible, Sendable {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

/// A parser for the part of TOML a config file needs: tables, arrays of tables, dotted
/// keys, strings, numbers, booleans, arrays and inline tables. Dates are left out.
public enum TOML {
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var parser = Parser(Array(text.unicodeScalars))
        return try parser.document()
    }

    /// Formats a value the way the parser reads it back.
    public static func format(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s): return quote(s)
        case .integer(let i): return String(i)
        case .float(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map(format).joined(separator: ", ") + "]"
        case .table(let table):
            return "{ " + table.keys.sorted().map { "\(formatKey($0)) = \(format(table[$0]!))" }.joined(separator: ", ") + " }"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    public static func formatKey(_ key: String) -> String {
        let bare = !key.isEmpty && key.unicodeScalars.allSatisfy(Parser.isBareKeyScalar)
        return bare ? key : quote(key)
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        var line = 1

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        static func isBareKeyScalar(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }

        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        func error(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

        mutating func advance() {
            if s[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        /// Skips spaces, newlines and comments.
        mutating func skipTrivia() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    advance()
                } else if c == "#" {
                    while let d = peek, d != "\n" { advance() }
                } else {
                    break
                }
            }
        }

        mutating func expectLineEnd() throws {
            skipSpaces()
            if peek == "#" { while let d = peek, d != "\n" { advance() } }
            if peek == "\r" { advance() }
            guard atEnd || peek == "\n" else { throw error("expected the line to end here") }
        }

        mutating func document() throws -> [String: TOMLValue] {
            var root: [String: TOMLValue] = [:]
            var currentPath: [String] = []
            var definedTables = Set<[String]>()
            while true {
                skipTrivia()
                guard let c = peek else { break }
                if c == "[" {
                    advance()
                    let isArray = peek == "["
                    if isArray { advance() }
                    skipSpaces()
                    let path = try keyPath()
                    skipSpaces()
                    guard peek == "]" else { throw error("expected ']' to close the table header") }
                    advance()
                    if isArray {
                        guard peek == "]" else { throw error("expected ']]' to close the array-of-tables header") }
                        advance()
                        try appendTable(at: path, in: &root)
                    } else {
                        guard !definedTables.contains(path) else { throw error("table [\(path.joined(separator: "."))] is defined twice") }
                        definedTables.insert(path)
                        try ensureTable(at: path, in: &root)
                    }
                    currentPath = path
                    try expectLineEnd()
                } else {
                    let path = try keyPath()
                    skipSpaces()
                    guard peek == "=" else { throw error("expected '=' after the key") }
                    advance()
                    skipSpaces()
                    let value = try value()
                    try insert(value, at: currentPath, key: path, in: &root)
                    try expectLineEnd()
                }
            }
            return root
        }

        mutating func keyPath() throws -> [String] {
            var parts = [try key()]
            skipSpaces()
            while peek == "." {
                advance()
                skipSpaces()
                parts.append(try key())
                skipSpaces()
            }
            return parts
        }

        mutating func key() throws -> String {
            if peek == "\"" { return try basicString() }
            if peek == "'" { return try literalString() }
            var out = ""
            while let c = peek, Self.isBareKeyScalar(c) {
                out.unicodeScalars.append(c)
                advance()
            }
            guard !out.isEmpty else { throw error("expected a key") }
            return out
        }

        mutating func value() throws -> TOMLValue {
            guard let c = peek else { throw error("expected a value") }
            switch c {
            case "\"":
                if lookingAt("\"\"\"") { return .string(try multilineBasicString()) }
                return .string(try basicString())
            case "'":
                return .string(try literalString())
            case "[":
                return try arrayValue()
            case "{":
                return try inlineTable()
            case "t", "f":
                if lookingAt("true") { i += 4; return .bool(true) }
                if lookingAt("false") { i += 5; return .bool(false) }
                throw error("unexpected value")
            default:
                return try number()
            }
        }

        func lookingAt(_ text: String) -> Bool {
            var j = i
            for scalar in text.unicodeScalars {
                guard j < s.count, s[j] == scalar else { return false }
                j += 1
            }
            return true
        }

        mutating func basicString() throws -> String {
            advance() // opening quote
            var out = ""
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if c == "\n" { throw error("strings can't span lines; use \"\"\" for that") }
                advance()
                if c == "\"" { return out }
                if c == "\\" { out.unicodeScalars.append(try escape()) } else { out.unicodeScalars.append(c) }
            }
        }

        mutating func multilineBasicString() throws -> String {
            i += 3
            if peek == "\n" { advance() }
            var out = ""
            while true {
                guard let c = peek else { throw error("unterminated string") }
                if lookingAt("\"\"\"") { i += 3; return out }
                advance()
                if c == "\\" {
                    if let next = peek, next == "\n" || next == " " || next == "\t" {
                        // A backslash at line end trims the newline and leading whitespace.
                        while let d = peek, d == "\n" || d == " " || d == "\t" || d == "\r" { advance() }
                    } else {
                        out.unicodeScalars.append(try escape())
                    }
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let c = peek else { throw error("unterminated escape") }
            advance()
            switch c {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "u", "U":
                let length = c == "u" ? 4 : 8
                var hex = ""
                for _ in 0..<length {
                    guard let d = peek else { throw error("short unicode escape") }
                    hex.unicodeScalars.append(d)
                    advance()
                }
                guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { throw error("bad unicode escape") }
                return scalar
            default:
                throw error("unknown escape \\\(c)")
            }
        }

        mutating func literalString() throws -> String {
            advance()
            var out = ""
            while true {
                guard let c = peek, c != "\n" else { throw error("unterminated string") }
                advance()
                if c == "'" { return out }
                out.unicodeScalars.append(c)
            }
        }

        mutating func arrayValue() throws -> TOMLValue {
            advance()
            var items: [TOMLValue] = []
            while true {
                skipTrivia()
                if peek == "]" { advance(); return .array(items) }
                items.append(try value())
                skipTrivia()
                if peek == "," { advance(); continue }
                skipTrivia()
                guard peek == "]" else { throw error("expected ',' or ']' in array") }
                advance()
                return .array(items)
            }
        }

        mutating func inlineTable() throws -> TOMLValue {
            advance()
            var table: [String: TOMLValue] = [:]
            skipSpaces()
            if peek == "}" { advance(); return .table(table) }
            while true {
                skipSpaces()
                let path = try keyPath()
                skipSpaces()
                guard peek == "=" else { throw error("expected '=' in inline table") }
                advance()
                skipSpaces()
                let v = try value()
                var root: [String: TOMLValue] = table
                try insert(v, at: [], key: path, in: &root)
                table = root
                skipSpaces()
                if peek == "," { advance(); continue }
                guard peek == "}" else { throw error("expected ',' or '}' in inline table") }
                advance()
                return .table(table)
            }
        }

        mutating func number() throws -> TOMLValue {
            var text = ""
            while let c = peek, (c >= "0" && c <= "9") || c == "+" || c == "-" || c == "." || c == "e" || c == "E" || c == "_" {
                if c != "_" { text.unicodeScalars.append(c) }
                advance()
            }
            if let int = Int(text) { return .integer(int) }
            if let double = Double(text), !text.isEmpty {
                // Double reads a number too large to store as infinity, which nothing in a
                // config means and which crashes whatever turns it into an Int.
                guard double.isFinite else { throw error("'\(text)' is too large") }
                return .float(double)
            }
            throw error(text.isEmpty ? "expected a value" : "'\(text)' is not a number")
        }

        // MARK: Building the tree

        func insert(_ value: TOMLValue, at tablePath: [String], key: [String], in root: inout [String: TOMLValue]) throws {
            let full = tablePath + key
            try mutateTable(at: Array(full.dropLast()), in: &root, createMissing: true) { table in
                guard table[full.last!] == nil else { throw error("key '\(full.joined(separator: "."))' is set twice") }
                table[full.last!] = value
            }
        }

        func ensureTable(at path: [String], in root: inout [String: TOMLValue]) throws {
            try mutateTable(at: path, in: &root, createMissing: true) { _ in }
        }

        func appendTable(at path: [String], in root: inout [String: TOMLValue]) throws {
            try mutateTable(at: Array(path.dropLast()), in: &root, createMissing: true) { table in
                var items = table[path.last!]?.array ?? []
                if let existing = table[path.last!], existing.array == nil { throw error("'\(path.joined(separator: "."))' is not an array of tables") }
                items.append(.table([:]))
                table[path.last!] = .array(items)
            }
        }

        /// Walks to the table at `path`, descending into the last element of arrays of
        /// tables, which is where `[[x]]` followed by keys puts them.
        func mutateTable(at path: [String], in table: inout [String: TOMLValue], createMissing: Bool, _ body: (inout [String: TOMLValue]) throws -> Void) throws {
            guard let head = path.first else { try body(&table); return }
            let rest = Array(path.dropFirst())
            switch table[head] {
            case nil:
                var child: [String: TOMLValue] = [:]
                try mutateTable(at: rest, in: &child, createMissing: createMissing, body)
                table[head] = .table(child)
            case .table(var child):
                try mutateTable(at: rest, in: &child, createMissing: createMissing, body)
                table[head] = .table(child)
            case .array(var items):
                guard case .table(var last)? = items.last else { throw error("'\(head)' is not a table") }
                try mutateTable(at: rest, in: &last, createMissing: createMissing, body)
                items[items.count - 1] = .table(last)
                table[head] = .array(items)
            default:
                throw error("'\(head)' is a value, not a table")
            }
        }
    }
}

/// Edits single values in a TOML file while leaving comments and layout alone, so the
/// app and a hand-edited file can live together.
public enum TOMLEditor {
    public static func setting(_ value: TOMLValue, table: String, key: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let header = "[\(table)]"
        let rendered = "\(TOML.formatKey(key)) = \(TOML.format(value))"
        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            lines += ["", header, rendered, ""]
            return lines.joined(separator: "\n")
        }
        var end = lines.count
        for index in (headerIndex + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end = index
            break
        }
        for index in (headerIndex + 1)..<end {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let lineKey = trimmed[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if lineKey == key {
                // Keep a trailing comment on the line if there is one.
                let comment = trailingComment(of: lines[index])
                let indent = String(lines[index].prefix { $0 == " " || $0 == "\t" })
                lines[index] = indent + rendered + (comment.map { "  " + $0 } ?? "")
                return lines.joined(separator: "\n")
            }
        }
        // Insert after the last non-blank line of the table so blank separators stay put.
        var insertAt = end
        while insertAt > headerIndex + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert(rendered, at: insertAt)
        return lines.joined(separator: "\n")
    }

    static func trailingComment(of line: String) -> String? {
        var inString: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            if let open = inString {
                if c == "\\" && open == "\"" { index = line.index(after: index) } else if c == open { inString = nil }
            } else if c == "\"" || c == "'" {
                inString = c
            } else if c == "#" {
                return String(line[index...])
            }
            index = line.index(after: index)
        }
        return nil
    }
}
