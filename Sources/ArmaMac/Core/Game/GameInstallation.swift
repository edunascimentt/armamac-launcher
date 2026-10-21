import Foundation

/// One runnable Arma 3 binary inside an install folder.
struct GameExecutable: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case win64
        case win32
        case win64BattlEye
        case win32BattlEye
        /// `ArmA3 AS Native.app` — the arm64 build of the macOS port.
        case macOSAppleSilicon
        /// `ArmA3.app` — the x86-64 build, which runs under Rosetta on Apple Silicon.
        case macOSIntel

        var displayName: String {
            switch self {
            case .win64: "64-bit"
            case .win32: "32-bit"
            case .win64BattlEye: "64-bit (BattlEye)"
            case .win32BattlEye: "32-bit (BattlEye)"
            case .macOSAppleSilicon: "Apple Silicon"
            case .macOSIntel: "Intel (Rosetta)"
            }
        }

        /// BattlEye launchers re-spawn the real binary and are what public servers require.
        var usesBattlEye: Bool { self == .win64BattlEye || self == .win32BattlEye }
        var is64Bit: Bool { self != .win32 && self != .win32BattlEye }
        var isNative: Bool { self == .macOSAppleSilicon || self == .macOSIntel }

        /// Whether this build can pass a BattlEye check.
        ///
        /// Bohemia's Apple Silicon native build ships without BattlEye, so any server
        /// running it will reject the client — which is most public servers.
        /// The x86-64 "non-native" Mac build does support it.
        var supportsBattlEye: Bool { self != .macOSAppleSilicon }
    }

    var id: URL { url }
    var url: URL
    var kind: Kind

    /// Known binary names, in preference order. Matching is done against the real directory
    /// listing so a case-insensitive volume cannot yield the same bundle twice.
    private static let windowsNames: [(String, Kind)] = [
        ("arma3_x64.exe", .win64),
        ("arma3.exe", .win32),
        ("arma3battleye.exe", .win64BattlEye),
        ("arma3battleye_x64.exe", .win64BattlEye),
    ]

    private static let macNames: [(String, Kind)] = [
        ("ArmA3 AS Native.app", .macOSAppleSilicon),
        ("ArmA3.app", .macOSIntel),
        ("Arma 3.app", .macOSIntel),
        ("Arma3.app", .macOSIntel),
    ]

    static func discover(in directory: URL, container: RuntimeContainer) -> [GameExecutable] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
            ?? []
        // Real on-disk names keyed by lowercase, so we keep the exact spelling Arma uses.
        var byLowercaseName: [String: String] = [:]
        for entry in entries { byLowercaseName[entry.lowercased()] = entry }

        let candidates = container.isWindows ? windowsNames : macNames
        var found: [GameExecutable] = []
        var seen = Set<String>()

        for (name, kind) in candidates {
            guard let actual = byLowercaseName[name.lowercased()] else { continue }
            guard seen.insert(actual.lowercased()).inserted else { continue }
            found.append(GameExecutable(url: directory.appending(path: actual), kind: kind))
        }
        return found
    }
}

/// An Arma 3 install: where it is, which Steam library owns it, how to run it.
struct GameInstallation: Hashable, Sendable, Identifiable {
    var id: URL { directory }
    var directory: URL
    var library: SteamLibrary
    var executables: [GameExecutable]

    var container: RuntimeContainer { library.container }

    /// Folder the launcher symlinks workshop mods into, mirroring arma3-unix-launcher's
    /// approach so the game only ever sees paths under its own install directory.
    var workshopLinkDirectory: URL { directory.appending(path: "!Workshop") }

    var hasPreferredExecutable: Bool {
        executables.contains {
            $0.kind == .win64 || $0.kind == .macOSAppleSilicon || $0.kind == .macOSIntel
        }
    }

    /// The binary to launch for a given BattlEye preference.
    ///
    /// With BattlEye on, a build that cannot do BattlEye is heavily penalised — picking the
    /// faster Apple Silicon binary would otherwise get the player rejected by almost every
    /// public server. With BattlEye off, the arm64 build wins on Apple Silicon.
    func executable(battlEye: Bool, prefer64Bit: Bool = true) -> GameExecutable? {
        func rank(_ executable: GameExecutable) -> Int {
            var score = 0
            let kind = executable.kind

            if battlEye {
                if !kind.supportsBattlEye { score -= 100 }
                if kind.usesBattlEye { score += 8 }
            } else {
                if !kind.usesBattlEye { score += 8 }
                #if arch(arm64)
                if kind == .macOSAppleSilicon { score += 6 }
                #endif
            }
            if kind.is64Bit == prefer64Bit { score += 2 }
            return score
        }
        // `max` still returns the penalised build when it is the only one installed, so the
        // UI can warn rather than the launcher refusing to start.
        return executables.max { rank($0) < rank($1) }
    }

    /// Set when the build we would launch cannot satisfy a BattlEye check.
    func battlEyeUnavailable(for options: LaunchOptions) -> Bool {
        guard options.useBattlEye else { return false }
        guard let executable = executable(
            battlEye: options.useBattlEye, prefer64Bit: options.prefer64Bit
        ) else { return false }
        return !executable.kind.supportsBattlEye
    }

    var displayName: String {
        "\(directory.lastPathComponent) — \(library.displayName)"
    }

    /// Version string from the install, when the game wrote one.
    func readVersion() -> String? {
        let candidates = [
            directory.appending(path: "arma3.version"),
            directory.appending(path: "Steam/steam_appid.txt"),
        ]
        for candidate in candidates {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
