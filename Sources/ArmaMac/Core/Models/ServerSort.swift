import Foundation

/// A column the server list can be ordered by. Kept separate from `KeyPathComparator` so
/// the sort chain can be shown, edited and persisted.
enum ServerSortField: String, CaseIterable, Sendable, Identifiable, Codable {
    case players, ping, name, map, mods, status, freeSlots, fullness, country

    var id: String { rawValue }

    var title: String {
        switch self {
        case .players: "Players"
        case .ping: "Ping"
        case .name: "Name"
        case .map: "Map"
        case .mods: "Mod count"
        case .status: "Status"
        case .freeSlots: "Free slots"
        case .fullness: "How full"
        case .country: "Country"
        }
    }

    /// How this field reads when sorted ascending vs descending.
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .players: ascending ? "fewest first" : "most first"
        case .ping: ascending ? "lowest first" : "highest first"
        case .mods: ascending ? "fewest first" : "most first"
        case .freeSlots: ascending ? "fewest first" : "most first"
        case .fullness: ascending ? "emptiest first" : "fullest first"
        case .status: ascending ? "idle first" : "in-game first"
        case .name, .map, .country: ascending ? "A–Z" : "Z–A"
        }
    }

    var comparableKeyPath: PartialKeyPath<GameServer> {
        switch self {
        case .players: \GameServer.players
        case .ping: \GameServer.pingMilliseconds
        case .name: \GameServer.displayName
        case .map: \GameServer.map
        case .mods: \GameServer.modCount
        case .status: \GameServer.stateOrder
        case .freeSlots: \GameServer.freeSlots
        case .fullness: \GameServer.occupancyPercent
        case .country: \GameServer.countrySortKey
        }
    }

    func comparator(ascending: Bool) -> KeyPathComparator<GameServer> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .players: return KeyPathComparator(\GameServer.players, order: order)
        case .ping: return KeyPathComparator(\GameServer.pingMilliseconds, order: order)
        case .name: return KeyPathComparator(\GameServer.displayName, order: order)
        case .map: return KeyPathComparator(\GameServer.map, order: order)
        case .mods: return KeyPathComparator(\GameServer.modCount, order: order)
        case .status: return KeyPathComparator(\GameServer.stateOrder, order: order)
        case .freeSlots: return KeyPathComparator(\GameServer.freeSlots, order: order)
        case .fullness: return KeyPathComparator(\GameServer.occupancyPercent, order: order)
        case .country: return KeyPathComparator(\GameServer.countrySortKey, order: order)
        }
    }

    /// Sensible default direction when a field is added to the chain.
    var prefersAscending: Bool {
        switch self {
        case .ping, .name, .map, .country, .freeSlots: true
        case .players, .mods, .status, .fullness: false
        }
    }

    static func field(for keyPath: PartialKeyPath<GameServer>) -> ServerSortField? {
        allCases.first { $0.comparableKeyPath == keyPath }
    }
}

/// One level of the sort chain.
struct ServerSortRule: Codable, Hashable, Sendable, Identifiable {
    var field: ServerSortField
    var ascending: Bool

    var id: ServerSortField { field }
    var summary: String { "\(field.title) (\(field.directionLabel(ascending: ascending)))" }
}
