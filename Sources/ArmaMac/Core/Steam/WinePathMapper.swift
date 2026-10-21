import Foundation

/// Translates between host (macOS) paths and the Windows paths a Wine-hosted Arma expects,
/// using the prefix's `dosdevices` symlinks as the drive table.
struct WinePathMapper: Sendable {
    struct Drive: Sendable {
        var letter: String  // "c", "z", ...
        var target: URL     // host path the letter points at
    }

    let prefix: URL
    let drives: [Drive]

    init(prefix: URL) {
        self.prefix = prefix
        self.drives = Self.readDrives(prefix: prefix)
    }

    private static func readDrives(prefix: URL) -> [Drive] {
        let dosdevices = prefix.appending(path: "dosdevices")
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dosdevices,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { entry -> Drive? in
            let name = entry.lastPathComponent  // e.g. "c:", "z:", "c::" (device links)
            guard name.count == 2, name.hasSuffix(":") else { return nil }
            let letter = String(name.dropLast()).lowercased()
            guard let resolved = try? fileManager.destinationOfSymbolicLink(
                atPath: entry.path(percentEncoded: false)
            ) else { return nil }
            let target = resolved.hasPrefix("/")
                ? URL(filePath: resolved)
                : URL(filePath: resolved, relativeTo: dosdevices)
            return Drive(letter: letter, target: target.standardizedFileURL.resolvingSymlinksInPath())
        }
        // Longest target first so `C:` wins over `Z:` for paths inside the prefix.
        .sorted { $0.target.path(percentEncoded: false).count > $1.target.path(percentEncoded: false).count }
    }

    /// Host path → `C:\Games\...`. Returns nil when no drive covers the path.
    func windowsPath(for url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolved.path(percentEncoded: false)

        for drive in drives {
            let base = drive.target.path(percentEncoded: false)
            let normalizedBase = base == "/" ? "/" : base + "/"
            if path == base {
                return "\(drive.letter.uppercased()):\\"
            }
            if path.hasPrefix(normalizedBase) {
                let remainder = String(path.dropFirst(normalizedBase.count))
                let windows = remainder.replacingOccurrences(of: "/", with: "\\")
                return "\(drive.letter.uppercased()):\\\(windows)"
            }
        }
        return nil
    }

    /// `C:\Program Files\...` → host path.
    func hostURL(fromWindowsPath windowsPath: String) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2 else { return nil }
        let letter = String(normalized.prefix(1)).lowercased()
        guard normalized.dropFirst().hasPrefix(":") else { return nil }
        guard let drive = drives.first(where: { $0.letter == letter }) else { return nil }
        let remainder = normalized.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return remainder.isEmpty ? drive.target : drive.target.appending(path: remainder)
    }
}
