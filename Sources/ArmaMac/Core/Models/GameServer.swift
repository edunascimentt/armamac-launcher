import Foundation

/// A server endpoint. Arma listens for game traffic on `gamePort` and answers Steam
/// queries on `queryPort`, which is conventionally `gamePort + 1`.
struct ServerAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    var host: String
    var gamePort: UInt16
    var queryPort: UInt16

    init(host: String, gamePort: UInt16, queryPort: UInt16? = nil) {
        self.host = host
        self.gamePort = gamePort
        self.queryPort = queryPort ?? (gamePort == .max ? gamePort : gamePort &+ 1)
    }

    var description: String { "\(host):\(gamePort)" }
    var queryDescription: String { "\(host):\(queryPort)" }
}

/// Server availability as reported in the A2S keywords (`s` tag).
enum ServerState: Int, Codable, Sendable, CaseIterable {
    case none = 0
    case selectingMission = 1
    case editing = 2
    case assigningRoles = 3
    case sendingMission = 4
    case loadingGame = 5
    case briefing = 6
    case playing = 7
    case debriefing = 8
    case missionAborted = 9

    var displayName: String {
        switch self {
        case .none: "Idle"
        case .selectingMission: "Selecting mission"
        case .editing: "Editing"
        case .assigningRoles: "Slotting"
        case .sendingMission: "Sending mission"
        case .loadingGame: "Loading"
        case .briefing: "Briefing"
        case .playing: "Playing"
        case .debriefing: "Debriefing"
        case .missionAborted: "Aborted"
        }
    }

    /// Whether players can still join in a meaningful way.
    var isJoinable: Bool {
        switch self {
        case .assigningRoles, .briefing, .playing, .selectingMission: true
        default: false
        }
    }
}

/// One mod a server requires, as advertised over the Arma 3 server browser protocol.
struct ServerMod: Hashable, Codable, Sendable, Identifiable {
    var id: UInt64 { publishedFileID }
    var publishedFileID: UInt64
    var name: String
    var hash: UInt32
}

struct ServerDLC: Hashable, Codable, Sendable, Identifiable {
    var id: UInt64 { appID }
    var appID: UInt64
    var name: String
    var hash: UInt32
    var isCreatorDLC: Bool
}

/// Everything we know about one server, merged from the master list, A2S_INFO and A2S_RULES.
struct GameServer: Identifiable, Hashable, Codable, Sendable {
    var id: ServerAddress { address }
    var address: ServerAddress

    // A2S_INFO
    var name: String = ""
    var map: String = ""
    var gameDescription: String = ""
    var players: Int = 0
    var maxPlayers: Int = 0
    var botCount: Int = 0
    var isPasswordProtected: Bool = false
    var isVAC: Bool = false
    var isDedicated: Bool = true
    var version: String = ""
    var os: String = ""
    var ping: Duration?

    // Parsed from the A2S_INFO keywords blob.
    var battlEye: Bool = false
    var verifySignatures: Bool = false
    var requiredVersion: String = ""
    var requiredBuild: UInt32 = 0
    var serverState: ServerState = .none
    var difficulty: UInt8 = 0
    var equalModRequired: Bool = false
    var allowedFilePatching: Bool = false
    var country: String = ""
    var platform: String = ""
    var timeLeft: Duration?
    var loadedContentHash: String = ""

    // A2S_RULES / A3SBP
    var mods: [ServerMod] = []
    var dlcs: [ServerDLC] = []
    var signatures: [String] = []
    /// Nil until a rules query succeeded; distinguishes "vanilla" from "not asked yet".
    var modsLoaded: Bool = false

    // A2S_PLAYER
    var playerList: [ServerPlayer] = []
    /// Whether a query has actually asked for players. An empty `playerList` is ambiguous
    /// on its own — the server may simply be empty.
    var playersLoaded: Bool = false

    var lastRefreshed: Date = .now
    var queryFailed: Bool = false

    var isFull: Bool { maxPlayers > 0 && players >= maxPlayers }
    var isEmpty: Bool { players == 0 }
    var isModded: Bool { !mods.isEmpty }

    // Sort-friendly projections: `Table` needs non-optional `Comparable` key paths.
    var displayName: String { name.isEmpty ? address.description : name }
    /// Unreachable servers sort last rather than first.
    var pingMilliseconds: Int {
        guard let ping else { return .max }
        return Int(ping.components.seconds * 1_000
            + ping.components.attoseconds / 1_000_000_000_000_000)
    }
    var modCount: Int { mods.count }
    var stateOrder: Int { serverState.rawValue }
    /// Open slots. Sorting on this finds servers with room without hiding busy ones.
    var freeSlots: Int { max(0, maxPlayers - players) }
    /// How full the server is, 0–100. Distinguishes 20/20 from 20/100.
    var occupancyPercent: Int { Int((occupancy * 100).rounded()) }
    /// Empty country codes sort last rather than first.
    var countrySortKey: String { country.isEmpty ? "zz" : country }

    var occupancy: Double {
        guard maxPlayers > 0 else { return 0 }
        return Double(players) / Double(maxPlayers)
    }

    /// Deep link that makes the Steam client join this server directly.
    var steamConnectURL: URL? {
        URL(string: "steam://connect/\(address.host):\(address.gamePort)")
    }
}

struct ServerPlayer: Hashable, Codable, Sendable, Identifiable {
    var id: Int { index }
    var index: Int
    var name: String
    var score: Int32
    var duration: Duration
}
