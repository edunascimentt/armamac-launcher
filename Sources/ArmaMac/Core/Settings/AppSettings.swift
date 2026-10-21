import Foundation

/// Everything the launcher remembers between runs, stored as JSON in Application Support.
struct AppSettings: Codable, Sendable, Equatable {
    // UI
    /// Sidebar tab to restore on launch.
    var lastSection = "home"

    // Game
    var selectedInstallationPath: String?
    var launchMode: LaunchMode = .modded
    var launchOptions = LaunchOptions()
    var launchThroughSteam = false
    /// Recreate the `!Workshop` symlink farm before each launch.
    var linkWorkshopMods = true

    // Mods
    var extraModDirectories: [String] = []
    var enabledModIDs: [String] = []
    var presets: [Preset] = []
    var showOfficialMods = true

    // Workshop
    /// Fetch a server's missing mods — and join once they land — without prompting.
    var autoInstallServerMods = true

    // Server browser
    var steamWebAPIKey = ""
    var queryTimeoutMilliseconds = 1_400
    var queryConcurrency = 48
    var favouriteServers: [String] = []
    var recentServers: [String] = []
    var hideEmptyServers = false
    var hideFullServers = false
    var hidePasswordProtected = false
    var autoRefreshOnOpen = true
    /// Read every server's mod list after the ping pass, so the Mods column is filled in
    /// for the whole list rather than only for rows the user selects.
    var autoLoadModLists = true

    /// Multi-level server sort, highest priority first.
    var sortRules: [ServerSortRule] = [
        ServerSortRule(field: .players, ascending: false),
        ServerSortRule(field: .ping, ascending: true),
    ]

    static let empty = AppSettings()

    init() {}

    /// Decoded leniently: every field falls back to its default when absent.
    ///
    /// The synthesized decoder throws on a missing key, which would discard the user's
    /// entire settings file whenever this struct gains a property.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()

        // `try?` flattens the optional, so a missing key and a malformed value both fall
        // back — which is exactly what tolerant loading needs.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        lastSection = value(.lastSection, fallback.lastSection)
        selectedInstallationPath = try? container.decodeIfPresent(
            String.self, forKey: .selectedInstallationPath
        )
        launchMode = value(.launchMode, fallback.launchMode)
        launchOptions = value(.launchOptions, fallback.launchOptions)
        launchThroughSteam = value(.launchThroughSteam, fallback.launchThroughSteam)
        linkWorkshopMods = value(.linkWorkshopMods, fallback.linkWorkshopMods)
        extraModDirectories = value(.extraModDirectories, fallback.extraModDirectories)
        enabledModIDs = value(.enabledModIDs, fallback.enabledModIDs)
        presets = value(.presets, fallback.presets)
        showOfficialMods = value(.showOfficialMods, fallback.showOfficialMods)
        autoInstallServerMods = value(.autoInstallServerMods, fallback.autoInstallServerMods)
        steamWebAPIKey = value(.steamWebAPIKey, fallback.steamWebAPIKey)
        queryTimeoutMilliseconds = value(
            .queryTimeoutMilliseconds, fallback.queryTimeoutMilliseconds
        )
        queryConcurrency = value(.queryConcurrency, fallback.queryConcurrency)
        favouriteServers = value(.favouriteServers, fallback.favouriteServers)
        recentServers = value(.recentServers, fallback.recentServers)
        hideEmptyServers = value(.hideEmptyServers, fallback.hideEmptyServers)
        hideFullServers = value(.hideFullServers, fallback.hideFullServers)
        hidePasswordProtected = value(.hidePasswordProtected, fallback.hidePasswordProtected)
        autoRefreshOnOpen = value(.autoRefreshOnOpen, fallback.autoRefreshOnOpen)
        autoLoadModLists = value(.autoLoadModLists, fallback.autoLoadModLists)
        sortRules = value(.sortRules, fallback.sortRules)
    }
}

/// Loads and saves `AppSettings`, debouncing writes so typing in a text field does not
/// hammer the disk.
@MainActor
final class SettingsStore {
    static let directory: URL = AppPaths.supportDirectory
    static let fileURL: URL = directory.appending(path: "settings.json")

    private var saveTask: Task<Void, Never>?

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return .empty }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // A settings file from an older build should not stop the app from starting.
            return .empty
        }
    }

    func scheduleSave(_ settings: AppSettings) {
        saveTask?.cancel()
        saveTask = Task { [settings] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            save(settings)
        }
    }

    func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(
                at: Self.directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("ArmaMac: could not save settings: \(error.localizedDescription)")
        }
    }
}
