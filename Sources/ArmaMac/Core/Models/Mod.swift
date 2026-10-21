import Foundation

/// Where a mod physically lives, which decides how it is referenced on the command line
/// and whether the launcher is allowed to delete or update it.
enum ModOrigin: String, Codable, Sendable, CaseIterable {
    /// Downloaded through Steam Workshop (`steamapps/workshop/content/107410/<id>`).
    case workshop
    /// Shipped with the game or a DLC (`<Arma 3>/curator`, `<Arma 3>/expansion`, ...).
    case bundled
    /// A folder the user added by hand.
    case local

    var displayName: String {
        switch self {
        case .workshop: "Workshop"
        case .bundled: "Official"
        case .local: "Local"
        }
    }
}

/// A single loadable Arma 3 mod folder.
struct Mod: Identifiable, Hashable, Codable, Sendable {
    /// Stable identity: the workshop id when we have one, otherwise the folder path.
    var id: String { publishedFileID.map(String.init) ?? path.path(percentEncoded: false) }

    var path: URL
    var origin: ModOrigin
    /// Steam Workshop published file id, parsed from `meta.cpp` or the containing folder name.
    var publishedFileID: UInt64?
    /// `name` from `mod.cpp`, falling back to the folder name.
    var name: String
    /// Free-form fields from `mod.cpp`, kept for the detail inspector.
    var author: String?
    var modVersion: String?
    var website: URL?
    var descriptionText: String?
    /// `timestamp` from `meta.cpp` — Steam's last-update marker, in 100ns ticks.
    var metaTimestamp: UInt64?
    var sizeOnDisk: Int64?
    var lastScanned: Date

    /// Folder name as it appears on disk, e.g. `@CBA_A3` or `2154365400`.
    var folderName: String { path.lastPathComponent }

    /// True when the mod folder contains no PBOs — usually a broken or partial download.
    var isEmpty: Bool { sizeOnDisk.map { $0 < 1_024 } ?? false }

    var workshopURL: URL? {
        publishedFileID.flatMap {
            URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\($0)")
        }
    }

    var steamProtocolURL: URL? {
        publishedFileID.flatMap { URL(string: "steam://url/CommunityFilePage/\($0)") }
    }
}

/// Extra Workshop metadata fetched from the Steam Web API, cached alongside the library.
struct WorkshopDetails: Hashable, Codable, Sendable {
    var publishedFileID: UInt64
    var title: String
    var previewURL: URL?
    var fileSize: Int64?
    var timeUpdated: Date?
    var timeCreated: Date?
    var subscriptions: Int?
    var favorited: Int?
    var creatorSteamID: String?
    var descriptionText: String?
    var tags: [String]

    /// The server told us this mod exists but Steam has no record of it (delisted / private).
    var isUnavailable: Bool { title.isEmpty }
}

/// A named, ordered mod selection the user can switch between.
struct Preset: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Mod identities in load order. Workshop ids are stored as strings so a preset
    /// survives a mod being moved on disk.
    var modIDs: [String]
    var createdAt: Date = .now
    var updatedAt: Date = .now
    /// Set when the preset was generated from a server's mod list.
    var sourceServer: String?
}
