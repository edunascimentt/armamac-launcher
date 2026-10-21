import Foundation

/// Lenient reader for the flat `key = value;` config files Arma ships beside every mod
/// (`mod.cpp`, `meta.cpp`).
///
/// These are technically full config-class syntax, but the fields launchers care about are
/// always top-level scalars, so nested `class { ... }` blocks are skipped rather than parsed.
enum ArmaConfigParser {
    struct Entry: Sendable {
        var string: String?
        var number: Double?

        var intValue: Int? { number.map(Int.init) ?? string.flatMap(Int.init) }
        var uint64Value: UInt64? {
            if let number, number >= 0, number <= Double(UInt64.max) { return UInt64(number) }
            return string.flatMap(UInt64.init)
        }
    }

    static func parse(contentsOf url: URL) -> [String: Entry] {
        // Mod authors use every encoding under the sun; try UTF-8 then fall back to Latin-1
        // so a stray byte does not cost us the whole mod name.
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    static func parse(_ text: String) -> [String: Entry] {
        var result: [String: Entry] = [:]
        var depth = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)

            // Strip line comments that are not inside a quoted string.
            if let commentRange = rangeOfUnquotedComment(in: line) {
                line = String(line[line.startIndex..<commentRange]).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }

            let depthBeforeLine = depth
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            depth = max(0, depth)

            // Only take assignments that sit at the top level on a line of their own; a line
            // carrying a brace either opens or closes a class body.
            guard depthBeforeLine == 0, !line.contains("{"), !line.contains("}") else { continue }
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("class ") else { continue }

            let key = line[line.startIndex..<equals]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "[]", with: "")
                .lowercased()
            guard !key.isEmpty, !key.contains(" ") else { continue }

            var value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value = String(value.dropLast()) }
            value = value.trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                let unquoted = String(value.dropFirst().dropLast())
                    // Arma escapes embedded quotes by doubling them.
                    .replacingOccurrences(of: "\"\"", with: "\"")
                result[key] = Entry(string: unquoted, number: nil)
            } else if let number = Double(value) {
                result[key] = Entry(string: value, number: number)
            } else if !value.isEmpty {
                result[key] = Entry(string: value, number: nil)
            }
        }
        return result
    }

    private static func rangeOfUnquotedComment(in line: String) -> String.Index? {
        var inQuotes = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" { inQuotes.toggle() }
            if !inQuotes, character == "/", previous == "/" {
                return line.index(before: index)
            }
            previous = character
            index = line.index(after: index)
        }
        return nil
    }
}
