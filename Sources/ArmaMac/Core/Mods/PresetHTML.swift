import Foundation
import RegexBuilder

/// Reads and writes the HTML preset files the official Arma 3 Launcher exports, so presets
/// can be shared with Windows players and unit websites.
enum PresetHTML {
    struct ImportedMod: Sendable, Hashable, Identifiable {
        var id: String { publishedFileID.map(String.init) ?? name }
        var name: String
        var publishedFileID: UInt64?
        var isDLC: Bool = false
    }

    struct ImportedPreset: Sendable {
        var name: String
        var mods: [ImportedMod]
        var dlcs: [ImportedMod]
    }

    // MARK: - Import

    /// Pulls the mod rows out of a preset file. The official launcher emits one
    /// `<tr data-type="ModContainer">` per mod with a display name and a workshop link.
    static func parse(html: String, fallbackName: String = "Imported preset") -> ImportedPreset {
        let name = presetName(in: html) ?? fallbackName
        let modListRange = sectionRange(in: html, className: "mod-list")
        let dlcListRange = sectionRange(in: html, className: "dlc-list")

        let mods = parseRows(in: modListRange.map { String(html[$0]) } ?? html, isDLC: false)
        let dlcs = dlcListRange.map { parseRows(in: String(html[$0]), isDLC: true) } ?? []

        return ImportedPreset(name: name, mods: mods, dlcs: dlcs)
    }

    private static func parseRows(in html: String, isDLC: Bool) -> [ImportedMod] {
        var results: [ImportedMod] = []
        var seen = Set<String>()

        // Rows are simple and regular; splitting on the row marker is more forgiving of the
        // launcher's whitespace quirks than a full HTML parse.
        let rows = html.components(separatedBy: "<tr")
        for row in rows.dropFirst() {
            guard let displayName = firstMatch(
                in: row, pattern: #"data-type="DisplayName"\s*>([^<]*)<"#
            ) else { continue }

            let link = firstMatch(in: row, pattern: #"href="([^"]*)""#)
            let publishedID = link.flatMap(workshopID(fromURL:))
            let cleanName = decodeEntities(displayName).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { continue }

            let mod = ImportedMod(name: cleanName, publishedFileID: publishedID, isDLC: isDLC)
            guard seen.insert(mod.id).inserted else { continue }
            results.append(mod)
        }
        return results
    }

    static func workshopID(fromURL url: String) -> UInt64? {
        guard let value = firstMatch(in: url, pattern: #"[?&]id=(\d+)"#) else { return nil }
        return UInt64(value)
    }

    private static func presetName(in html: String) -> String? {
        firstMatch(in: html, pattern: #"<strong>([^<]*)</strong>"#)
            .map(decodeEntities)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sectionRange(in html: String, className: String) -> Range<String.Index>? {
        guard let start = html.range(of: "class=\"\(className)\"") else { return nil }
        let tail = html[start.upperBound...]
        guard let end = tail.range(of: "</div>") else { return start.upperBound..<html.endIndex }
        return start.upperBound..<end.lowerBound
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: text, range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        var output = text
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        return output
    }

    // MARK: - Export

    /// Exports a server's advertised modset, so it can be shared with players on any
    /// platform without having the mods installed locally first.
    static func export(name: String, serverMods: [ServerMod]) -> String {
        let rows = serverMods.map { mod -> String in
            let link = "https://steamcommunity.com/sharedfiles/filedetails/?id=\(mod.publishedFileID)"
            let title = mod.name.isEmpty ? "Workshop item \(mod.publishedFileID)" : mod.name
            return """
                  <tr data-type="ModContainer">
                    <td data-type="DisplayName">\(escape(title))</td>
                    <td>
                      <span class="from-steam">Steam</span>
                    </td>
                    <td>
                      <a href="\(link)" data-type="Link">\(link)</a>
                    </td>
                  </tr>
            """
        }
        return document(name: name, rows: rows.joined(separator: "\n"))
    }

    /// Produces a file the official launcher (and other tools) can import.
    static func export(name: String, mods: [Mod]) -> String {
        let rows = mods.map { mod -> String in
            let link = mod.publishedFileID.map {
                "https://steamcommunity.com/sharedfiles/filedetails/?id=\($0)"
            }
            let origin = mod.publishedFileID == nil ? "Local" : "Steam"
            let originClass = mod.publishedFileID == nil ? "from-local" : "from-steam"
            let linkCell = link.map {
                "<a href=\"\($0)\" data-type=\"Link\">\($0)</a>"
            } ?? escape(mod.path.path(percentEncoded: false))

            return """
                  <tr data-type="ModContainer">
                    <td data-type="DisplayName">\(escape(mod.name))</td>
                    <td>
                      <span class="\(originClass)">\(origin)</span>
                    </td>
                    <td>
                      \(linkCell)
                    </td>
                  </tr>
            """
        }.joined(separator: "\n")

        return document(name: name, rows: rows)
    }

    private static func document(name: String, rows: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html>
          <!--Created by ArmaMac Launcher-->
          <head>
            <meta name="arma:Type" content="preset" />
            <meta name="arma:PresetName" content="\(escape(name))" />
            <meta name="generator" content="ArmaMac Launcher" />
            <title>Arma 3 Preset \(escape(name))</title>
            <style>
              body { margin: 0; padding: 0; font-family: Arial, sans-serif; font-size: 12px; }
              h1 { padding: 1em 0 1em 0; font-size: 16px; }
              table { background: #f4f4f4; border-collapse: collapse; padding: 1em; }
              td { padding: 0.4em 1em 0.4em 1em; }
              .from-steam { color: #000; }
              .from-local { color: gray; font-style: italic; }
            </style>
          </head>
          <body>
            <h1>Arma 3 - Preset <strong>\(escape(name))</strong></h1>
            <p>To import this preset, drag this file onto the Arma 3 Launcher window.</p>
            <div class="mod-list">
              <table>
        \(rows)
              </table>
            </div>
          </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
