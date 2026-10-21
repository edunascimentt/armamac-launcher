import Foundation

/// Arma 3's Steam application id. Used for manifests, workshop paths and master queries.
enum Arma3 {
    static let appID: UInt64 = 107_410
    static let appIDString = "107410"
}

/// A Steam installation root — the folder that contains `steamapps`.
///
/// On macOS this is either the native client's support folder or a Steam install inside a
/// Wine prefix (CrossOver or Whisky), which is where a playable Arma 3 actually lives now
/// that the native port is gone.
struct SteamLibrary: Hashable, Sendable, Identifiable {
    var id: URL { root }
    /// Folder containing `steamapps`.
    var root: URL
    var container: RuntimeContainer

    var steamapps: URL { root.appending(path: "steamapps") }
    var common: URL { steamapps.appending(path: "common") }
    var workshopContent: URL {
        steamapps.appending(path: "workshop/content/\(Arma3.appIDString)")
    }
    var workshopManifest: URL {
        steamapps.appending(path: "workshop/appworkshop_\(Arma3.appIDString).acf")
    }
    var appManifest: URL {
        steamapps.appending(path: "appmanifest_\(Arma3.appIDString).acf")
    }

    var displayName: String {
        switch container {
        case .native: "Steam (macOS)"
        case let .crossover(bottle, _): "CrossOver · \(bottle)"
        case let .wine(name, _, _): "Wine · \(name)"
        }
    }
}

/// How Windows binaries in a given library get executed.
enum RuntimeContainer: Hashable, Sendable {
    /// Native macOS binaries — the discontinued Arma 3 macOS port.
    case native
    /// A CrossOver bottle, driven through CrossOver's `wine` wrapper.
    case crossover(bottle: String, prefix: URL)
    /// A plain Wine prefix (Whisky, Game Porting Toolkit, hand-rolled) with a `wine` binary.
    case wine(name: String, prefix: URL, binary: URL)

    var prefix: URL? {
        switch self {
        case .native: nil
        case let .crossover(_, prefix): prefix
        case let .wine(_, prefix, _): prefix
        }
    }

    var isWindows: Bool {
        if case .native = self { return false }
        return true
    }
}

/// Locates Steam libraries and the Arma 3 install inside them.
struct SteamLocator: Sendable {
    static let crossOverApp = URL(filePath: "/Applications/CrossOver.app")
    static var crossOverWine: URL {
        crossOverApp.appending(path: "Contents/SharedSupport/CrossOver/bin/wine")
    }

    private var fileManager: FileManager { .default }
    private var home: URL { fileManager.homeDirectoryForCurrentUser }

    /// Canonical key for a directory. `URL.standardizedFileURL` keeps the trailing-slash
    /// distinction, so `/a/b` and `/a/b/` would otherwise look like different libraries.
    static func pathKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath()
            .path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Every Steam library we can find, native first.
    func discoverLibraries() -> [SteamLibrary] {
        var libraries: [SteamLibrary] = []
        var seen = Set<String>()

        func add(_ library: SteamLibrary) {
            guard seen.insert(Self.pathKey(library.root)).inserted else { return }
            libraries.append(library)
        }

        for root in nativeSteamRoots() where isSteamRoot(root) {
            add(SteamLibrary(root: root, container: .native))
            for extra in additionalLibraryFolders(steamRoot: root, container: .native) {
                add(extra)
            }
        }

        for container in discoverWineContainers() {
            guard let prefix = container.prefix else { continue }
            for root in steamRoots(inPrefix: prefix) where isSteamRoot(root) {
                add(SteamLibrary(root: root, container: container))
                for extra in additionalLibraryFolders(steamRoot: root, container: container) {
                    add(extra)
                }
            }
        }

        return libraries
    }

    /// Wine-ish containers on this machine that could host a Windows Steam.
    func discoverWineContainers() -> [RuntimeContainer] {
        var containers: [RuntimeContainer] = []

        // CrossOver bottles.
        if fileManager.fileExists(atPath: Self.crossOverWine.path(percentEncoded: false)) {
            for bottles in crossOverBottleRoots() {
                for bottle in subdirectories(of: bottles) {
                    let prefix = bottle
                    guard fileManager.fileExists(
                        atPath: prefix.appending(path: "drive_c").path(percentEncoded: false)
                    ) else { continue }
                    containers.append(
                        .crossover(bottle: bottle.lastPathComponent, prefix: prefix)
                    )
                }
            }
        }

        // Whisky and other prefixes need a `wine` on disk; without one we cannot launch.
        if let wine = locateStandaloneWine() {
            for prefix in whiskyBottles() {
                containers.append(
                    .wine(name: prefixDisplayName(prefix), prefix: prefix, binary: wine)
                )
            }
            let defaultPrefix = home.appending(path: ".wine")
            if fileManager.fileExists(
                atPath: defaultPrefix.appending(path: "drive_c").path(percentEncoded: false)
            ) {
                containers.append(.wine(name: "~/.wine", prefix: defaultPrefix, binary: wine))
            }
        }

        return containers
    }

    // MARK: - Arma 3

    /// Arma 3 install folders across all libraries, best candidate first.
    func discoverInstallations(in libraries: [SteamLibrary]) -> [GameInstallation] {
        var seen = Set<String>()
        return libraries.compactMap { library -> GameInstallation? in
            let directory = armaDirectory(in: library)
            guard let directory, fileManager.fileExists(atPath: directory.path(percentEncoded: false))
            else { return nil }
            // Two libraries can point at the same folder; only surface it once.
            guard seen.insert(Self.pathKey(directory)).inserted else { return nil }
            let executables = GameExecutable.discover(in: directory, container: library.container)
            guard !executables.isEmpty else { return nil }
            return GameInstallation(
                directory: directory,
                library: library,
                executables: executables
            )
        }
        .sorted { lhs, rhs in
            // Prefer installs that actually have the 64-bit binary and more content.
            if lhs.hasPreferredExecutable != rhs.hasPreferredExecutable {
                return lhs.hasPreferredExecutable
            }
            return lhs.executables.count > rhs.executables.count
        }
    }

    /// Reads `installdir` from the app manifest, falling back to the conventional name.
    func armaDirectory(in library: SteamLibrary) -> URL? {
        let manifestDir = (try? ValveKeyValues.parse(contentsOf: library.appManifest))?
            .value(at: "AppState", "installdir")?
            .stringValue
        let candidates = [manifestDir, "Arma 3"].compactMap(\.self)
        for name in candidates {
            let url = library.common.appending(path: name)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return nil
    }

    // MARK: - Roots

    private func nativeSteamRoots() -> [URL] {
        [
            home.appending(path: "Library/Application Support/Steam"),
            home.appending(path: "Library/Application Support/Steam/Steam.AppBundle/Steam"),
        ]
    }

    private func crossOverBottleRoots() -> [URL] {
        [
            home.appending(path: "Library/Application Support/CrossOver/Bottles"),
            URL(filePath: "/Library/Application Support/CrossOver/Bottles"),
        ]
    }

    private func whiskyBottles() -> [URL] {
        let containers = [
            home.appending(path: "Library/Containers/com.isaacmarovitz.Whisky/Bottles"),
            home.appending(path: "Library/Application Support/com.isaacmarovitz.Whisky/Bottles"),
        ]
        return containers.flatMap { subdirectories(of: $0) }
    }

    /// Steam installs inside a Wine prefix, covering both Program Files variants.
    private func steamRoots(inPrefix prefix: URL) -> [URL] {
        let driveC = prefix.appending(path: "drive_c")
        return [
            driveC.appending(path: "Program Files (x86)/Steam"),
            driveC.appending(path: "Program Files/Steam"),
            driveC.appending(path: "Steam"),
        ]
    }

    private func locateStandaloneWine() -> URL? {
        let candidates = [
            "/usr/local/bin/wine",
            "/opt/homebrew/bin/wine",
            "/opt/homebrew/bin/wine64",
            "/usr/local/opt/game-porting-toolkit/bin/wine64",
            "/opt/homebrew/opt/game-porting-toolkit/bin/wine64",
        ]
        return candidates
            .map { URL(filePath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    private func isSteamRoot(_ url: URL) -> Bool {
        fileManager.fileExists(
            atPath: url.appending(path: "steamapps").path(percentEncoded: false)
        )
    }

    /// Extra libraries listed in `libraryfolders.vdf`, resolved back to host paths.
    private func additionalLibraryFolders(
        steamRoot: URL,
        container: RuntimeContainer
    ) -> [SteamLibrary] {
        let vdf = steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        guard let parsed = try? ValveKeyValues.parse(contentsOf: vdf),
              let folders = parsed["libraryfolders"]?.objectValue
        else { return [] }

        let mapper = container.prefix.map { WinePathMapper(prefix: $0) }
        return folders.values.compactMap { entry -> SteamLibrary? in
            guard let raw = entry["path"]?.stringValue, !raw.isEmpty else { return nil }
            let hostPath: URL? = if let mapper, raw.contains(":\\") || raw.contains(":/") {
                mapper.hostURL(fromWindowsPath: raw)
            } else {
                URL(filePath: raw)
            }
            guard let hostPath, isSteamRoot(hostPath),
                  Self.pathKey(hostPath) != Self.pathKey(steamRoot)
            else { return nil }
            return SteamLibrary(root: hostPath, container: container)
        }
    }

    private func subdirectories(of url: URL) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func prefixDisplayName(_ prefix: URL) -> String {
        // Whisky bottles are UUID-named folders with a metadata plist holding the real name.
        let metadata = prefix.appending(path: "Metadata.plist")
        if let data = try? Data(contentsOf: metadata),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, format: nil
           ) as? [String: Any],
           let info = plist["Info"] as? [String: Any],
           let name = info["name"] as? String, !name.isEmpty {
            return name
        }
        return prefix.lastPathComponent
    }
}
