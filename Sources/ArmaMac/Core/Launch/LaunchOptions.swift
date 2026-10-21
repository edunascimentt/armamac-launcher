import Foundation

/// The launch parameters the official launcher exposes, plus the macOS-specific ones.
struct LaunchOptions: Codable, Hashable, Sendable {
    // Game
    var skipIntro = true
    var noSplash = true
    var noPause = false
    var windowed = false
    var noLogs = false
    var showScriptErrors = false
    var filePatching = false
    var checkSignatures = false
    var enableHyperThreading = false
    var hugePages = false
    var emptyWorld = false

    // Performance
    var maxMemoryMB: Int?
    var cpuCount: Int?
    var extraThreads: Int?
    var maxVRAMMB: Int?
    var mallocLibrary: String?

    // Profile
    var profileName: String?
    var profilesDirectory: String?

    // Anything the UI does not model, appended verbatim.
    var customParameters: String = ""

    /// BattlEye is required by most public servers; disabling it needs the non-BE binary.
    var useBattlEye = true
    var prefer64Bit = true

    /// Renders the switches (not the mods or the connect info) as command-line arguments.
    func gameArguments() -> [String] {
        var arguments: [String] = []

        if skipIntro { arguments.append("-skipIntro") }
        if noSplash { arguments.append("-noSplash") }
        if noPause { arguments.append("-noPause") }
        if windowed { arguments.append("-window") }
        if noLogs { arguments.append("-noLogs") }
        if showScriptErrors { arguments.append("-showScriptErrors") }
        if filePatching { arguments.append("-filePatching") }
        if checkSignatures { arguments.append("-checkSignatures") }
        if enableHyperThreading { arguments.append("-enableHT") }
        if hugePages { arguments.append("-hugepages") }
        if emptyWorld { arguments.append("-world=empty") }

        if let maxMemoryMB { arguments.append("-maxMem=\(maxMemoryMB)") }
        if let cpuCount { arguments.append("-cpuCount=\(cpuCount)") }
        if let extraThreads { arguments.append("-exThreads=\(extraThreads)") }
        if let maxVRAMMB { arguments.append("-maxVRAM=\(maxVRAMMB)") }
        if let mallocLibrary, !mallocLibrary.isEmpty { arguments.append("-malloc=\(mallocLibrary)") }
        if let profileName, !profileName.isEmpty { arguments.append("-name=\(profileName)") }
        if let profilesDirectory, !profilesDirectory.isEmpty {
            arguments.append("-profiles=\(profilesDirectory)")
        }

        arguments.append(contentsOf: Self.splitCustomParameters(customParameters))
        return arguments
    }

    /// Splits a free-form parameter string, honouring quotes so `-mod="a b"` survives.
    static func splitCustomParameters(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?

        for character in text {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { arguments.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }
}

/// What to load when the game starts.
enum LaunchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// No `-mod=` at all — the game and its official DLC only.
    case vanilla
    /// The enabled mods, in load order.
    case modded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vanilla: "Vanilla"
        case .modded: "With Mods"
        }
    }

    var subtitle: String {
        switch self {
        case .vanilla: "Official content only"
        case .modded: "Your enabled load order"
        }
    }

    var symbol: String {
        switch self {
        case .vanilla: "shield.lefthalf.filled"
        case .modded: "shippingbox.fill"
        }
    }
}

/// Where the launcher should connect on start-up, if anywhere.
struct ConnectTarget: Hashable, Sendable {
    var address: ServerAddress
    var password: String?

    func arguments() -> [String] {
        var arguments = ["-connect=\(address.host)", "-port=\(address.gamePort)"]
        if let password, !password.isEmpty { arguments.append("-password=\(password)") }
        return arguments
    }
}

/// Everything needed to start the game once: which binary, which arguments, how to run it.
struct LaunchPlan: Sendable {
    var installation: GameInstallation
    var executable: GameExecutable
    /// Arguments for the game itself, mods included.
    var arguments: [String]
    var environment: [String: String] = [:]
    /// Human-readable command, shown in the UI and copyable for debugging.
    var displayCommand: String = ""
}
