import Foundation

/// Presentation-only Markdown blocks. Content remains text, never executable.
enum ChatGPTReplyBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case list([(marker: String, text: String)])
    case table(headers: [String], rows: [[String]], alignments: [ChatGPTTableAlignment])
    case code(String)
    case quote(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.paragraph(a), .paragraph(b)), let (.code(a), .code(b)), let (.quote(a), .quote(b)): return a == b
        case let (.heading(a, x), .heading(b, y)): return a == b && x == y
        case let (.list(a), .list(b)): return a.map(\.marker) == b.map(\.marker) && a.map(\.text) == b.map(\.text)
        case let (.table(a, x, p), .table(b, y, q)): return a == b && x == y && p == q
        default: return false
        }
    }
}
enum ChatGPTTableAlignment: Equatable { case leading, center, trailing }

enum ChatGPTReplyParser {
    static func parse(_ text: String) -> [ChatGPTReplyBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [ChatGPTReplyBlock] = [], paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); index += 1; continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = String(line.prefix(3))
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                result.append(.code(code.joined(separator: "\n"))); continue
            }
            if index + 1 < lines.count, line.contains("|"),
               let alignments = separators(lines[index + 1]), alignments.count == cells(line).count {
                flush()
                let headers = cells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    var row = cells(lines[index])
                    guard row.count <= headers.count else { break }
                    row += Array(repeating: "", count: headers.count - row.count)
                    rows.append(row); index += 1
                }
                result.append(.table(headers: headers, rows: rows, alignments: alignments)); continue
            }
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                flush(); result.append(.heading(level, String(line.dropFirst(level + 1)))); index += 1; continue
            }
            if let item = listItem(line) {
                flush()
                var items = [item]; index += 1
                while index < lines.count, let next = listItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next); index += 1
                }
                result.append(.list(items)); continue
            }
            if line.hasPrefix("> ") {
                flush(); result.append(.quote(String(line.dropFirst(2)))); index += 1; continue
            }
            paragraph.append(lines[index]); index += 1
        }
        flush()
        return result
    }
    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return ("•", String(line.dropFirst(2))) }
        let digits = line.prefix(while: { $0.isNumber })
        let remaining = line.dropFirst(digits.count)
        if !digits.isEmpty && (remaining.hasPrefix(". ") || remaining.hasPrefix(") ")) {
            return (String(digits) + ".", String(remaining.dropFirst(2)))
        }
        return nil
    }
    private static func separators(_ line: String) -> [ChatGPTTableAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty, parts.allSatisfy({ cell in
            let stripped = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return stripped.count >= 3 && stripped.allSatisfy { $0 == "-" }
        }) else { return nil }
        return parts.map { $0.hasPrefix(":") && $0.hasSuffix(":") ? .center : $0.hasSuffix(":") ? .trailing : .leading }
    }
    private static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") && !value.hasSuffix("\\|") { value.removeLast() }
        var result: [String] = [], cell = "", escaped = false, inCode = false
        for character in value {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character); escaped = false
            } else if character == "\\" { escaped = true }
            else if character == "`" { inCode.toggle(); cell.append(character) }
            else if character == "|" && !inCode { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result
    }
}
