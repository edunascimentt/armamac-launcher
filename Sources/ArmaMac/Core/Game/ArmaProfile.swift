import Foundation

/// Surgical editor for Arma's `key=value;` config files (`.Arma3Profile`, `Arma3.cfg`).
///
/// These files hold hundreds of settings the game wrote itself, so they are edited in place
/// rather than regenerated: only the requested key's line changes, and everything else —
/// including `class` blocks and unknown keys — is preserved byte for byte.
struct ArmaConfigEditor: Sendable {
    private(set) var lines: [String]

    /// Preserved so a file Arma wrote with CRLF is written back the same way.
    private let lineEnding: String

    init(text: String) {
        // Arma writes CRLF on Windows, which is what profiles inside a Wine prefix look
        // like. Splitting on "\n" alone left a stray "\r" on every line, so values parsed
        // as "0.75;\r" — the semicolon never stripped, the number never read, and the
        // setting silently fell back to its default.
        let usesCRLF = text.contains("\r\n")
        lineEnding = usesCRLF ? "\r\n" : "\n"
        lines = text.components(separatedBy: lineEnding)
    }

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        self.init(text: text)
    }

    var text: String { lines.joined(separator: lineEnding) }

    /// Reads a top-level key. Keys inside `class` blocks are ignored, since the settings we
    /// edit all live at the root and a nested key of the same name would be a different one.
    func value(for key: String) -> String? {
        guard let index = indexOfTopLevelKey(key) else { return nil }
        return Self.parseValue(from: lines[index])
    }

    func doubleValue(for key: String) -> Double? {
        value(for: key).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    func intValue(for key: String) -> Int? {
        value(for: key).flatMap { Int($0) } ?? doubleValue(for: key).map { Int($0) }
    }

    /// Replaces a top-level key's value, or appends the key when it is absent.
    mutating func setValue(_ value: String, for key: String) {
        if let index = indexOfTopLevelKey(key) {
            let indent = lines[index].prefix { $0 == " " || $0 == "\t" }
            lines[index] = "\(indent)\(key)=\(value);"
        } else {
            // Append before any trailing blank lines so the file stays tidy.
            var insertion = lines.count
            while insertion > 0, lines[insertion - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertion -= 1
            }
            lines.insert("\(key)=\(value);", at: insertion)
        }
    }

    mutating func setValue(_ value: Double, for key: String) {
        setValue(FieldOfView.format(value), for: key)
    }

    mutating func setValue(_ value: Int, for key: String) {
        setValue(String(value), for: key)
    }

    /// Finds a `key=...;` assignment at brace depth zero.
    private func indexOfTopLevelKey(_ key: String) -> Int? {
        var depth = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let depthBefore = depth
            depth += trimmed.filter { $0 == "{" }.count
            depth -= trimmed.filter { $0 == "}" }.count
            depth = max(0, depth)

            guard depthBefore == 0, !trimmed.contains("{"), !trimmed.contains("}") else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let candidate = trimmed[trimmed.startIndex..<equals]
                .trimmingCharacters(in: .whitespaces)
            if candidate == key { return index }
        }
        return nil
    }

    private static func parseValue(from line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        var value = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(";") { value = String(value.dropLast()) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Writes the file, keeping a one-time `.bak` of whatever was there before.
    func write(to url: URL) throws {
        let fileManager = FileManager.default
        let backup = url.appendingPathExtension("armamac-bak")
        if fileManager.fileExists(atPath: url.path(percentEncoded: false)),
           !fileManager.fileExists(atPath: backup.path(percentEncoded: false)) {
            try? fileManager.copyItem(at: url, to: backup)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// One Arma player profile on disk.
struct ArmaProfile: Identifiable, Hashable, Sendable {
    var id: URL { profileURL }
    /// The `.Arma3Profile` holding gameplay settings, including the FOV.
    var profileURL: URL
    /// `Arma3.cfg` in the same folder, holding video settings. May not exist yet.
    var configURL: URL?
    var name: String
    /// True for the default profile in `Documents/Arma 3`.
    var isDefault: Bool

    var displayName: String { isDefault ? "\(name) (default)" : name }
}

/// Finds Arma's profile folders across native and Wine installs.
struct ArmaProfileLocator: Sendable {
    private var fileManager: FileManager { .default }
    private var home: URL { fileManager.homeDirectoryForCurrentUser }

    /// Where the native macOS port keeps the game's "Documents" folder.
    ///
    /// The port is published by Virtual Programming and redirects Documents into its own
    /// Application Support container, so nothing Arma writes ever reaches `~/Documents`.
    /// Reading and writing there instead is why FOV edits appeared to save but never
    /// reached the game.
    var nativeGameDocuments: [URL] {
        let support = home.appending(path: "Library/Application Support")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: support, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("com.vpltd.") }
            .map { $0.appending(path: "GameDocuments") }
            .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
            .sorted { $0.path < $1.path }
    }

    /// Folders that can contain profiles, for the given installation. The folders the game
    /// itself uses come first, so they win when a name appears in more than one place.
    func profileDirectories(for installation: GameInstallation?) -> [URL] {
        var directories: [URL] = []

        for root in nativeGameDocuments {
            directories.append(root.appending(path: "Arma 3"))
            directories.append(root.appending(path: "Arma 3 - Other Profiles"))
        }

        // Plain `~/Documents`, which is where a Windows-style layout would put them.
        directories.append(home.appending(path: "Documents/Arma 3"))
        directories.append(home.appending(path: "Documents/Arma 3 - Other Profiles"))

        // Wine-hosted installs keep them inside the prefix's fake Documents folder.
        if let prefix = installation?.container.prefix {
            let users = prefix.appending(path: "drive_c/users")
            if let entries = try? fileManager.contentsOfDirectory(
                at: users, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                for user in entries {
                    directories.append(user.appending(path: "Documents/Arma 3"))
                    directories.append(user.appending(path: "Documents/Arma 3 - Other Profiles"))
                }
            }
        }

        return directories.filter {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// Every profile found, default first.
    func profiles(for installation: GameInstallation?, extraDirectory: URL? = nil) -> [ArmaProfile] {
        var found: [ArmaProfile] = []
        var seen = Set<String>()

        var roots = profileDirectories(for: installation)
        if let extraDirectory,
           fileManager.fileExists(atPath: extraDirectory.path(percentEncoded: false)) {
            roots.insert(extraDirectory, at: 0)
        }

        for root in roots {
            let isDefaultRoot = root.lastPathComponent == "Arma 3"
            // Profiles sit either directly in the folder or one level down, per profile name.
            var candidates = profileFiles(in: root)
            for sub in subdirectories(of: root) {
                candidates.append(contentsOf: profileFiles(in: sub))
            }

            for url in candidates {
                let folder = url.deletingLastPathComponent()
                let name = Self.displayName(
                    fromFileName: url.deletingPathExtension().lastPathComponent
                )
                // Keyed on the name, not the path: the same profile can exist both where
                // the game keeps it and in `~/Documents`, and the game's copy — scanned
                // first — is the one worth showing.
                guard seen.insert(name.lowercased()).inserted else { continue }

                found.append(
                    ArmaProfile(
                        profileURL: url,
                        // Arma keeps one Arma3.cfg beside the default profile and shares it
                        // across named profiles, so fall back to it rather than reporting
                        // that a named profile has no video settings.
                        configURL: existingConfig(in: folder)
                            ?? existingConfig(in: root.deletingLastPathComponent()
                                .appending(path: "Arma 3")),
                        name: name,
                        isDefault: isDefaultRoot && folder.lastPathComponent == "Arma 3"
                    )
                )
            }
        }

        return found.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Creating and managing profiles

    enum ProfileError: LocalizedError {
        case emptyName
        case nameInUse(String)
        case cannotDeleteDefault
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: "Give the profile a name."
            case let .nameInUse(name): "A profile called “\(name)” already exists."
            case .cannotDeleteDefault:
                "The default profile cannot be deleted from here — Arma recreates it anyway."
            case let .failed(reason): reason
            }
        }
    }

    /// Arma percent-encodes anything outside `A–Z a–z 0–9 _ -` in profile file names, so a
    /// profile called "Alpha Team" is stored as `Alpha%20Team.Arma3Profile`.
    static func fileName(for profileName: String) -> String {
        var encoded = ""
        for byte in Array(profileName.utf8) {
            let character = Character(UnicodeScalar(byte))
            if character.isLetter && character.isASCII || character.isNumber && character.isASCII
                || character == "_" || character == "-" {
                encoded.append(character)
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func displayName(fromFileName fileName: String) -> String {
        fileName.removingPercentEncoding ?? fileName
    }

    /// The folder the game actually reads user files from. A profile created anywhere else
    /// is invisible to Arma, however correct its contents.
    private var documentsRoot: URL {
        nativeGameDocuments.first ?? home.appending(path: "Documents")
    }

    /// Folder that holds named profiles, mirroring where Arma puts the ones it creates.
    private var otherProfilesRoot: URL {
        documentsRoot.appending(path: "Arma 3 - Other Profiles")
    }

    private var defaultProfileRoot: URL {
        documentsRoot.appending(path: "Arma 3")
    }

    /// Creates a profile, optionally starting from a copy of an existing one.
    ///
    /// Named profiles go in `Arma 3 - Other Profiles/<name>/`, which is exactly where Arma
    /// itself writes them, so the game picks them up with `-name=<name>`.
    @discardableResult
    func createProfile(named name: String, copying source: ArmaProfile? = nil) throws -> ArmaProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.emptyName }

        let fileName = Self.fileName(for: trimmed)
        let folder = otherProfilesRoot.appending(path: fileName)
        let url = folder.appending(path: "\(fileName).Arma3Profile")

        guard !fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ProfileError.nameInUse(trimmed)
        }

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            if let source,
               let contents = try? Data(contentsOf: source.profileURL) {
                try contents.write(to: url, options: .atomic)
            } else {
                try Data(Self.starterProfile.utf8).write(to: url, options: .atomic)
            }
            // Copy the video config too, so a duplicate really is a duplicate.
            if let source, let sourceConfig = source.configURL,
               let configData = try? Data(contentsOf: sourceConfig) {
                try? configData.write(to: folder.appending(path: "Arma3.cfg"), options: .atomic)
            }
        } catch let error as ProfileError {
            throw error
        } catch {
            throw ProfileError.failed(error.localizedDescription)
        }

        return ArmaProfile(
            profileURL: url,
            configURL: existingConfig(in: folder),
            name: trimmed,
            isDefault: false
        )
    }

    /// Creates the default profile in `Documents/Arma 3`, for setups where Arma has never run.
    @discardableResult
    func createDefaultProfile(named name: String = NSUserName()) throws -> ArmaProfile {
        let fileName = Self.fileName(for: name)
        let url = defaultProfileRoot.appending(path: "\(fileName).Arma3Profile")

        do {
            try fileManager.createDirectory(at: defaultProfileRoot, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try Data(Self.starterProfile.utf8).write(to: url, options: .atomic)
            }
        } catch {
            throw ProfileError.failed(error.localizedDescription)
        }

        return ArmaProfile(
            profileURL: url,
            configURL: existingConfig(in: defaultProfileRoot),
            name: name,
            isDefault: true
        )
    }

    @discardableResult
    func renameProfile(_ profile: ArmaProfile, to newName: String) throws -> ArmaProfile {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.emptyName }
        guard trimmed != profile.name else { return profile }

        let fileName = Self.fileName(for: trimmed)
        let folder = profile.profileURL.deletingLastPathComponent()
        let currentBaseName = profile.profileURL.deletingPathExtension().lastPathComponent

        // Only rename the folder when it is genuinely this profile's own folder — Arma
        // names it after the profile. A loose .Arma3Profile sitting directly in
        // "Arma 3 - Other Profiles" must never drag that shared folder along with it.
        let ownsFolder = !profile.isDefault && folder.lastPathComponent == currentBaseName
        let destinationFolder = ownsFolder
            ? folder.deletingLastPathComponent().appending(path: fileName)
            : folder
        let destination = destinationFolder.appending(path: "\(fileName).Arma3Profile")

        guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw ProfileError.nameInUse(trimmed)
        }
        if ownsFolder,
           fileManager.fileExists(atPath: destinationFolder.path(percentEncoded: false)) {
            throw ProfileError.nameInUse(trimmed)
        }

        do {
            // Rename the file first. If the folder move then fails, the profile is still
            // consistent — the scanner identifies profiles by file name, not folder name.
            let renamedInPlace = folder.appending(path: "\(fileName).Arma3Profile")
            if renamedInPlace != profile.profileURL {
                try fileManager.moveItem(at: profile.profileURL, to: renamedInPlace)
            }
            if ownsFolder {
                try fileManager.moveItem(at: folder, to: destinationFolder)
            }
        } catch {
            throw ProfileError.failed(error.localizedDescription)
        }

        return ArmaProfile(
            profileURL: destination,
            configURL: existingConfig(in: destinationFolder),
            name: trimmed,
            isDefault: profile.isDefault
        )
    }

    /// Moves a profile to the Trash rather than destroying it outright.
    func deleteProfile(_ profile: ArmaProfile) throws {
        guard !profile.isDefault else { throw ProfileError.cannotDeleteDefault }
        let folder = profile.profileURL.deletingLastPathComponent()
        let baseName = profile.profileURL.deletingPathExtension().lastPathComponent
        // Only delete the folder when it belongs to this profile alone; otherwise remove
        // just the file, so a shared folder is never taken down with it.
        let ownsFolder = folder.lastPathComponent == baseName
        let target = ownsFolder ? folder : profile.profileURL
        do {
            try fileManager.trashItem(at: target, resultingItemURL: nil)
        } catch {
            throw ProfileError.failed(error.localizedDescription)
        }
    }

    private func existingConfig(in folder: URL) -> URL? {
        let config = folder.appending(path: "Arma3.cfg")
        return fileManager.fileExists(atPath: config.path(percentEncoded: false)) ? config : nil
    }

    /// A minimal profile holding only what the launcher manages; Arma fills in the rest.
    private static var starterProfile: String {
        let defaults = FieldOfView.arma3Default
        return """
        version=1;
        fovTop=\(defaults.fovTopText);
        fovLeft=\(defaults.fovLeftText);

        """
    }

    private func profileFiles(in directory: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "arma3profile" else { return false }
            // Arma writes sidecars beside the real profile — `<name>.3den.Arma3Profile`
            // and `<name>.vars.Arma3Profile`. Profile names are percent-encoded, so a real
            // one never keeps a literal dot in its base name; the sidecars always do.
            return !url.deletingPathExtension().lastPathComponent.contains(".")
        }
    }

    private func subdirectories(of url: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
