import Foundation

/// Walks Steam's workshop folder, the game folder and any user-added folders, turning each
/// mod directory into a `Mod`.
struct ModScanner: Sendable {
    /// Bundled content that ships with the game and is loaded by name rather than path.
    static let officialModFolders: Set<String> = [
        "curator", "heli", "kart", "mark", "expansion", "jets", "argo", "orange",
        "tacops", "tank", "contact", "enoch", "csla", "gm", "vn", "ws", "spe",
        "rf", "ef", "aow",
    ]

    var includeOfficial = true
    /// Computing directory sizes is the slow part of a scan; off by default.
    var computeSizes = false

    func scan(installation: GameInstallation?, extraDirectories: [URL] = []) -> [Mod] {
        var mods: [Mod] = []
        var seenPaths = Set<String>()
        var seenWorkshopIDs = Set<UInt64>()

        func append(_ mod: Mod?) {
            guard let mod else { return }
            // Resolve symlinks: after a modded launch the same mod exists twice on disk —
            // once in the workshop folder and once as a link in `!Workshop`. Keying on the
            // raw path listed both, which also produced duplicate SwiftUI identities.
            let key = mod.path.standardizedFileURL.resolvingSymlinksInPath()
                .path(percentEncoded: false)
            guard seenPaths.insert(key).inserted else { return }
            if let id = mod.publishedFileID, !seenWorkshopIDs.insert(id).inserted { return }
            mods.append(mod)
        }

        if let installation {
            for url in workshopFolders(library: installation.library) {
                append(makeMod(at: url, origin: .workshop))
            }
            for url in gameFolders(installation: installation) {
                let isOfficial = Self.officialModFolders.contains(
                    url.lastPathComponent.lowercased()
                )
                if isOfficial && !includeOfficial { continue }
                append(makeMod(at: url, origin: isOfficial ? .bundled : .local))
            }
        }

        for directory in extraDirectories {
            // A user-added path may be a single mod or a folder of mods.
            if isModDirectory(directory) {
                append(makeMod(at: directory, origin: .local))
            } else {
                for url in subdirectories(of: directory) where isModDirectory(url) {
                    append(makeMod(at: url, origin: .local))
                }
            }
        }

        return mods.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Workshop items live in numbered folders under the library that owns the game.
    func workshopFolders(library: SteamLibrary) -> [URL] {
        subdirectories(of: library.workshopContent).filter(isModDirectory)
    }

    /// `@Mod` folders sitting directly in the Arma install, plus official DLC folders.
    func gameFolders(installation: GameInstallation) -> [URL] {
        var folders = subdirectories(of: installation.directory).filter { url in
            let name = url.lastPathComponent
            // Skip our own symlink farm — those mods are already listed as workshop items.
            guard name != "!Workshop" else { return false }
            return name.hasPrefix("@") || Self.officialModFolders.contains(name.lowercased())
        }
        .filter(isModDirectory)

        // Mods the user symlinked into !Workshop by hand still deserve a listing if their
        // target is gone from the workshop folder.
        folders.append(
            contentsOf: subdirectories(of: installation.workshopLinkDirectory)
                .filter(isModDirectory)
        )
        return folders
    }

    /// A directory counts as a mod when Arma would be able to load it.
    func isModDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDirectory
        ), isDirectory.boolValue else { return false }

        for marker in ["addons", "Addons", "mod.cpp", "meta.cpp"] {
            if fileManager.fileExists(
                atPath: url.appending(path: marker).path(percentEncoded: false)
            ) { return true }
        }
        return false
    }

    func makeMod(at url: URL, origin: ModOrigin) -> Mod? {
        guard isModDirectory(url) else { return nil }

        let meta = ArmaConfigParser.parse(contentsOf: url.appending(path: "meta.cpp"))
        let config = ArmaConfigParser.parse(contentsOf: url.appending(path: "mod.cpp"))

        // Workshop folders are named after the published file id, which is the most
        // reliable source when meta.cpp is missing or stale.
        let folderID = UInt64(url.lastPathComponent)
        let publishedID = meta["publishedid"]?.uint64Value ?? folderID

        let name = config["name"]?.string?.trimmingCharacters(in: .whitespaces)
            ?? meta["name"]?.string?.trimmingCharacters(in: .whitespaces)
            ?? url.lastPathComponent

        return Mod(
            path: url,
            origin: origin,
            publishedFileID: publishedID.flatMap { $0 == 0 ? nil : $0 },
            name: name.isEmpty ? url.lastPathComponent : name,
            author: config["author"]?.string,
            modVersion: config["version"]?.string,
            website: (config["actionname"]?.string).flatMap { _ in
                config["action"]?.string.flatMap(URL.init(string:))
            } ?? config["action"]?.string.flatMap(URL.init(string:)),
            descriptionText: config["description"]?.string,
            metaTimestamp: meta["timestamp"]?.uint64Value,
            sizeOnDisk: computeSizes ? directorySize(of: url) : nil,
            lastScanned: .now
        )
    }

    // MARK: - Helpers

    private func subdirectories(of url: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { entry in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true { return true }
            // `isDirectory` is false for a symlink even when it points at a folder, which
            // made every link in `!Workshop` invisible to the scanner. Follow it.
            guard values?.isSymbolicLink == true else { return false }
            let resolved = entry.resolvingSymlinksInPath()
            return (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
        }
    }

    func directorySize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
