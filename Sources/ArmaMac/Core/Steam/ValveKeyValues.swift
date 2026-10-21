import Foundation

/// Minimal reader for Valve's text KeyValues format (`.vdf` / `.acf`).
///
/// The format is a tree of quoted string pairs and brace-delimited blocks:
/// ```
/// "AppState"
/// {
///     "appid"  "107410"
///     "UserConfig" { "language" "english" }
/// }
/// ```
/// Conditional suffixes (`[$WIN32]`), `#include` and unquoted tokens are not used by the
/// files we read, so they are skipped rather than interpreted.
indirect enum ValveKeyValues: Sendable, Equatable {
    case string(String)
    case object([String: ValveKeyValues])

    subscript(key: String) -> ValveKeyValues? {
        guard case let .object(dict) = self else { return nil }
        // Valve keys are matched case-insensitively by the Steam client.
        if let exact = dict[key] { return exact }
        let lowered = key.lowercased()
        return dict.first { $0.key.lowercased() == lowered }?.value
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var objectValue: [String: ValveKeyValues]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var intValue: Int? { stringValue.flatMap(Int.init) }
    var uint64Value: UInt64? { stringValue.flatMap(UInt64.init) }

    /// Follows a key path, e.g. `kv.value(at: "AppState", "UserConfig", "language")`.
    func value(at path: String...) -> ValveKeyValues? {
        path.reduce(self as ValveKeyValues?) { node, key in node?[key] }
    }

    static func parse(contentsOf url: URL) throws -> ValveKeyValues {
        // Steam writes UTF-8 but occasionally slips in invalid bytes from user-supplied
        // strings (server names, mod titles), so decode leniently rather than throwing.
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    static func parse(_ text: String) throws -> ValveKeyValues {
        var parser = Parser(text: Array(text.unicodeScalars))
        return try parser.parseRoot()
    }

    private struct Parser {
        let text: [Unicode.Scalar]
        var index = 0

        mutating func parseRoot() throws -> ValveKeyValues {
            var root: [String: ValveKeyValues] = [:]
            while true {
                skipTrivia()
                guard index < text.count else { break }
                guard let key = try readToken() else { break }
                skipTrivia()
                if index < text.count, text[index] == "{" {
                    index += 1
                    root[key] = try parseObject()
                } else if let value = try readToken() {
                    root[key] = .string(value)
                } else {
                    break
                }
            }
            return .object(root)
        }

        mutating func parseObject() throws -> ValveKeyValues {
            var dict: [String: ValveKeyValues] = [:]
            while true {
                skipTrivia()
                guard index < text.count else { throw VDFError.unexpectedEnd }
                if text[index] == "}" {
                    index += 1
                    return .object(dict)
                }
                guard let key = try readToken() else { throw VDFError.unexpectedEnd }
                skipTrivia()
                guard index < text.count else { throw VDFError.unexpectedEnd }
                if text[index] == "{" {
                    index += 1
                    dict[key] = try parseObject()
                } else {
                    guard let value = try readToken() else { throw VDFError.unexpectedEnd }
                    dict[key] = .string(value)
                }
            }
        }

        /// Skips whitespace, `//` line comments and `[$CONDITION]` suffixes.
        mutating func skipTrivia() {
            while index < text.count {
                let scalar = text[index]
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                    index += 1
                } else if scalar == "/", index + 1 < text.count, text[index + 1] == "/" {
                    while index < text.count, text[index] != "\n" { index += 1 }
                } else if scalar == "[" {
                    while index < text.count, text[index] != "]" { index += 1 }
                    if index < text.count { index += 1 }
                } else {
                    return
                }
            }
        }

        mutating func readToken() throws -> String? {
            skipTrivia()
            guard index < text.count else { return nil }
            if text[index] == "}" { return nil }

            if text[index] == "\"" {
                index += 1
                var scalars = String.UnicodeScalarView()
                while index < text.count {
                    let scalar = text[index]
                    if scalar == "\\", index + 1 < text.count {
                        index += 1
                        switch text[index] {
                        case "n": scalars.append("\n")
                        case "t": scalars.append("\t")
                        case "\\": scalars.append("\\")
                        case "\"": scalars.append("\"")
                        case let other: scalars.append(other)
                        }
                        index += 1
                    } else if scalar == "\"" {
                        index += 1
                        return String(scalars)
                    } else {
                        scalars.append(scalar)
                        index += 1
                    }
                }
                throw VDFError.unterminatedString
            }

            // Bare token — accepted for robustness even though Steam always quotes.
            var scalars = String.UnicodeScalarView()
            while index < text.count {
                let scalar = text[index]
                if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
                    || scalar == "{" || scalar == "}" {
                    break
                }
                scalars.append(scalar)
                index += 1
            }
            return scalars.isEmpty ? nil : String(scalars)
        }
    }

    enum VDFError: Error, LocalizedError {
        case unexpectedEnd
        case unterminatedString

        var errorDescription: String? {
            switch self {
            case .unexpectedEnd: "Unexpected end of Valve KeyValues data."
            case .unterminatedString: "Unterminated string in Valve KeyValues data."
            }
        }
    }
}
