import Foundation
import Observation

/// Filter and sort state for the server list.
struct ServerFilter: Equatable, Sendable {
    enum ModFilter: String, CaseIterable, Sendable, Identifiable {
        case any, vanilla, modded
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .any: "Any"
            case .vanilla: "Vanilla"
            case .modded: "Modded"
            }
        }
    }

    enum Scope: String, CaseIterable, Sendable, Identifiable {
        case all, favourites, recent, playable
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: "All servers"
            case .favourites: "Favourites"
            case .recent: "Recent"
            case .playable: "Ready to join"
            }
        }
        var symbol: String {
            switch self {
            case .all: "globe"
            case .favourites: "star"
            case .recent: "clock"
            case .playable: "checkmark.seal"
            }
        }
    }

    var searchText = ""
    var scope: Scope = .all
    var hideEmpty = false
    var hideFull = false
    var hidePasswordProtected = false
    var requireBattlEye = false
    var modFilter: ModFilter = .any
    /// Only show servers whose entire mod list is already installed locally.
    var onlyInstalledMods = false
    var maxPingMilliseconds: Int?
    var minPlayers: Int?
    var mapName: String?
}

/// Owns the server list: fetching addresses, querying them, filtering and sorting.
@MainActor
@Observable
final class ServerBrowserModel {
    enum Phase: Equatable, Sendable {
        case idle
        case fetchingList
        case querying(done: Int, total: Int)
        case readingMods(done: Int, total: Int)
        case finished(count: Int)
        case failed(String)
    }

    private(set) var serversByAddress: [ServerAddress: GameServer] = [:]
    private(set) var phase: Phase = .idle
    private(set) var lastRefresh: Date?

    var filter = ServerFilter() {
        didSet { if filter != oldValue { rebuildDerived() } }
    }

    /// The sort chain, highest priority first. Later levels break ties in earlier ones.
    /// The default answers "busiest server I can actually play on".
    var sortRules: [ServerSortRule] = [
        ServerSortRule(field: .players, ascending: false),
        ServerSortRule(field: .ping, ascending: true),
    ] {
        didSet { if sortRules != oldValue { rebuildDerived() } }
    }

    /// More than three levels stops being comprehensible and never changes the result.
    static let maxSortLevels = 3

    /// The comparator chain, in priority order. Duplicate fields are collapsed.
    var sortOrder: [KeyPathComparator<GameServer>] {
        var seen = Set<ServerSortField>()
        var comparators: [KeyPathComparator<GameServer>] = []
        for rule in sortRules where seen.insert(rule.field).inserted {
            comparators.append(rule.field.comparator(ascending: rule.ascending))
        }
        return comparators.isEmpty
            ? [ServerSortField.players.comparator(ascending: false)]
            : comparators
    }

    /// Clicking a table header promotes that column to the top of the chain and keeps the
    /// existing tie-breakers below it.
    func applyTableSort(_ order: [KeyPathComparator<GameServer>]) {
        guard let first = order.first,
              let field = ServerSortField.field(for: first.keyPath)
        else { return }
        var rules = sortRules.filter { $0.field != field }
        rules.insert(
            ServerSortRule(field: field, ascending: first.order == .forward), at: 0
        )
        sortRules = Array(rules.prefix(Self.maxSortLevels))
    }

    // MARK: Sort chain editing

    func sortField(atLevel level: Int) -> ServerSortField? {
        level < sortRules.count ? sortRules[level].field : nil
    }

    func setSortField(_ field: ServerSortField?, atLevel level: Int) {
        guard let field else {
            // Clearing a level drops everything below it too.
            if level < sortRules.count { sortRules.removeSubrange(level...) }
            return
        }
        // A field can only appear once in the chain.
        var rules = sortRules.enumerated()
            .filter { $0.offset == level || $0.element.field != field }
            .map(\.element)

        if level < rules.count {
            rules[level] = ServerSortRule(field: field, ascending: rules[level].ascending)
        } else {
            rules.append(ServerSortRule(field: field, ascending: field.prefersAscending))
        }
        sortRules = Array(rules.prefix(Self.maxSortLevels))
    }

    func sortAscending(atLevel level: Int) -> Bool {
        level < sortRules.count ? sortRules[level].ascending : true
    }

    func setSortAscending(_ ascending: Bool, atLevel level: Int) {
        guard level < sortRules.count else { return }
        sortRules[level].ascending = ascending
    }

    var sortSummary: String {
        sortRules.isEmpty ? "Default" : sortRules.map(\.summary).joined(separator: ", then ")
    }
    var selection: ServerAddress?
    var favourites: Set<String> = [] {
        didSet { if favourites != oldValue { rebuildDerived() } }
    }
    var recents: [String] = [] {
        didSet { if recents != oldValue { rebuildDerived() } }
    }

    /// Addresses whose rules (mod list) query is in flight.
    private(set) var loadingRules: Set<ServerAddress> = []

    private var refreshTask: Task<Void, Never>?
    private var pendingResults: [GameServer] = []
    private var flushTask: Task<Void, Never>?

    var isRefreshing: Bool {
        switch phase {
        case .fetchingList, .querying, .readingMods: true
        default: false
        }
    }

    var selectedServer: GameServer? {
        selection.flatMap { serversByAddress[$0] }
    }

    // MARK: - Derived list

    // Filtering and sorting a few thousand servers is cheap once, and ruinous when SwiftUI
    // does it several times per frame. These are recomputed only when their inputs change.
    private(set) var visibleServers: [GameServer] = []
    private(set) var responsiveCount = 0
    private(set) var totalPlayers = 0
    private(set) var knownMaps: [String] = []

    var allServers: [GameServer] { Array(serversByAddress.values) }

    /// Recomputes everything the UI reads. Call after any change to the server set,
    /// the filter or the sort chain.
    private func rebuildDerived() {
        let all = Array(serversByAddress.values)
        visibleServers = all.filter { matches($0) }.sorted(using: sortOrder)

        var responsive = 0
        var players = 0
        var maps = Set<String>()
        maps.reserveCapacity(256)
        for server in all {
            if !server.queryFailed { responsive += 1 }
            players += server.players
            if !server.map.isEmpty { maps.insert(server.map) }
        }
        responsiveCount = responsive
        totalPlayers = players
        knownMaps = maps.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func matches(_ server: GameServer) -> Bool {
        if server.queryFailed && server.name.isEmpty { return false }

        switch filter.scope {
        case .all: break
        case .favourites:
            guard favourites.contains(server.address.description) else { return false }
        case .recent:
            guard recents.contains(server.address.description) else { return false }
        case .playable:
            guard server.serverState.isJoinable, !server.isFull else { return false }
        }

        if !filter.searchText.isEmpty {
            let needle = filter.searchText
            let haystack = [server.name, server.map, server.address.host, server.gameDescription]
            // Mod names count too, so "ACE" finds every server running it.
            let matchesServer = haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
            let matchesMod = server.mods.contains { $0.name.localizedCaseInsensitiveContains(needle) }
            guard matchesServer || matchesMod else { return false }
        }
        if filter.hideEmpty, server.isEmpty { return false }
        if filter.hideFull, server.isFull { return false }
        if filter.hidePasswordProtected, server.isPasswordProtected { return false }
        if filter.requireBattlEye, !server.battlEye { return false }

        switch filter.modFilter {
        case .any: break
        case .vanilla:
            // Only meaningful once the rules query has run.
            guard !server.modsLoaded || server.mods.isEmpty else { return false }
        case .modded:
            guard server.isModded else { return false }
        }

        if filter.onlyInstalledMods, server.modsLoaded {
            guard server.mods.allSatisfy({ installedWorkshopIDs.contains($0.publishedFileID) })
            else { return false }
        }
        if let maxPing = filter.maxPingMilliseconds,
           let ping = server.ping,
           ping > .milliseconds(maxPing) { return false }
        if let minPlayers = filter.minPlayers, server.players < minPlayers { return false }
        if let mapName = filter.mapName, !mapName.isEmpty,
           server.map.compare(mapName, options: .caseInsensitive) != .orderedSame { return false }

        return true
    }

    /// Workshop ids present in the local library, used by the "installed mods only" filter.
    var installedWorkshopIDs: Set<UInt64> = [] {
        didSet { if installedWorkshopIDs != oldValue { rebuildDerived() } }
    }

    // MARK: - Refresh

    func refresh(settings: AppSettings) {
        refreshTask?.cancel()
        settingsForModPass = settings
        // Background priority keeps the query sweeps behind UI work on the cooperative pool.
        refreshTask = Task(priority: .utility) { await performRefresh(settings: settings) }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        flushPending()
        // Report the same number the completed path reports, not the raw list size.
        phase = .finished(count: responsiveCount)
    }

    /// Path to `libsteam_api.dylib`, set once installs are known. Its presence is what
    /// makes the keyless Steam-client route available.
    var steamDylib: URL?

    /// True when a full community list can be fetched at all.
    func canFetchFullList(settings: AppSettings) -> Bool {
        steamDylib != nil || !settings.steamWebAPIKey.isEmpty
    }

    private func performRefresh(settings: AppSettings) async {
        phase = .fetchingList
        let plan = ServerQueryPlan(
            includePlayers: false,
            // Fetching the mod list in the same session reuses the socket and the challenge
            // handshake, halving the work compared with a second sweep afterwards.
            includeRules: settings.autoLoadModLists,
            timeout: .milliseconds(settings.queryTimeoutMilliseconds)
        )
        let service = ServerQueryService(concurrency: settings.queryConcurrency)
        var problems: [String] = []

        // Preferred source: the running Steam client. Same list the in-client server
        // browser shows, no API key involved.
        if let steamDylib {
            do {
                let rows = try await SteamClientServerList().fetch(dylib: steamDylib)
                guard !Task.isCancelled else { return }
                if !rows.isEmpty {
                    adopt(rows: rows)
                    await queryAll(addresses: rows.map(\.0), plan: plan, service: service)
                    return
                }
                problems.append("Steam returned an empty server list.")
            } catch {
                guard !Task.isCancelled else { return }
                problems.append(error.localizedDescription)
            }
        }

        // Optional second source for anyone who would rather use a Web API key.
        if !settings.steamWebAPIKey.isEmpty {
            do {
                let rows = try await SteamWebAPIServerList(apiKey: settings.steamWebAPIKey).fetch()
                guard !Task.isCancelled else { return }
                adopt(rows: rows)
                await queryAll(addresses: rows.map(\.0), plan: plan, service: service)
                return
            } catch {
                guard !Task.isCancelled else { return }
                problems.append(error.localizedDescription)
            }
        }

        // Last resort: Valve's UDP master server. Its hostname no longer resolves, so this
        // almost always fails — it is kept because the endpoint has come and gone before.
        do {
            var master = MasterServerClient()
            master.options.timeout = .seconds(4)
            let addresses = try await master.fetchAddresses()
            guard !Task.isCancelled else { return }
            let live = Set(addresses)
            serversByAddress = serversByAddress.filter { live.contains($0.key) }
            rebuildDerived()
            await queryAll(addresses: addresses, plan: plan, service: service)
            return
        } catch {
            guard !Task.isCancelled else { return }
        }

        // Nothing global worked; fall back to whatever the user has pinned.
        let known = (Array(favourites) + recents).uniqued().compactMap(Self.parseAddress)
        if known.isEmpty {
            phase = .failed(
                problems.first
                    ?? "No server list source is available. Start Steam and sign in, then refresh."
            )
        } else {
            await queryAll(addresses: known, plan: plan, service: service)
        }
    }

    /// Replaces the list with a freshly fetched one, dropping servers that went away.
    private func adopt(rows: [(ServerAddress, GameServer)]) {
        let live = Set(rows.map(\.0))
        serversByAddress = serversByAddress.filter { live.contains($0.key) }
        defer { rebuildDerived() }
        for (address, server) in rows {
            // Keep any mod list we already fetched for this server.
            if var existing = serversByAddress[address], existing.modsLoaded {
                existing.name = server.name
                existing.map = server.map
                existing.players = server.players
                existing.maxPlayers = server.maxPlayers
                existing.isPasswordProtected = server.isPasswordProtected
                serversByAddress[address] = existing
            } else {
                serversByAddress[address] = server
            }
        }
        lastRefresh = .now
    }

    /// Parses a stored `host:port` key back into an address.
    static func parseAddress(_ text: String) -> ServerAddress? {
        let parts = text.split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 2_302 : 2_302
        return ServerAddress(host: host, gamePort: port)
    }

    /// Re-queries only the servers the user has pinned. Works without an API key.
    func refreshKnownServers(settings: AppSettings) {
        let known = (Array(favourites) + recents).uniqued().compactMap(Self.parseAddress)
        guard !known.isEmpty else { return }
        refreshTask?.cancel()
        settingsForModPass = settings
        refreshTask = Task(priority: .utility) {
            let plan = ServerQueryPlan(
                includePlayers: false,
                includeRules: false,
                timeout: .milliseconds(settings.queryTimeoutMilliseconds)
            )
            await queryAll(
                addresses: known,
                plan: plan,
                service: ServerQueryService(concurrency: settings.queryConcurrency)
            )
        }
    }

    private func queryAll(
        addresses: [ServerAddress],
        plan: ServerQueryPlan,
        service: ServerQueryService
    ) async {
        let total = addresses.count
        phase = .querying(done: 0, total: total)
        // Rules replies are multi-packet, so redraw at a calm cadence during the sweep.
        let existing = serversByAddress
        let counter = Counter()

        startFlushLoop()
        await service.queryAll(
            addresses: addresses, plan: plan, existing: existing
        ) { [weak self] server in
            let done = await counter.increment()
            await MainActor.run {
                guard let self else { return }
                self.enqueue(server)
                if done % 64 == 0 { self.phase = .querying(done: done, total: total) }
            }
        }
        stopFlushLoop()
        flushPending()

        guard !Task.isCancelled else { return }
        lastRefresh = .now
        phase = .finished(count: responsiveCount)

        // Only sweep what this pass actually covered: refreshing a handful of favourites
        // must not kick off a mod sweep across the whole community list.
        await autoLoadModLists(scope: addresses, settings: settingsForModPass)
    }

    /// Settings captured at refresh time, so the follow-up mod pass uses the same limits.
    private var settingsForModPass = AppSettings.empty

    /// Queries `A2S_RULES` for every server that answered, filling in the Mods column for
    /// the whole list. Rules are heavier than info queries, so this runs after the ping pass
    /// at lower concurrency and reports its own progress.
    private func autoLoadModLists(scope: [ServerAddress], settings: AppSettings) async {
        guard settings.autoLoadModLists else { return }
        // The main pass already asked for rules; this only retries the ones that did not
        // answer, which is a small fraction of the list.
        let candidates = Set(scope)
        let pending = serversByAddress.values
            .filter { candidates.contains($0.address) && !$0.queryFailed && !$0.modsLoaded }
            .map(\.address)
        guard !pending.isEmpty else { return }

        let total = pending.count
        phase = .readingMods(done: 0, total: total)

        let plan = ServerQueryPlan(
            includePlayers: false,
            includeRules: true,
            timeout: .milliseconds(max(settings.queryTimeoutMilliseconds, 1_800))
        )
        // Deliberately low: this is a long background sweep over thousands of servers and
        // must not cost the user frames while they browse.
        let service = ServerQueryService(concurrency: min(settings.queryConcurrency, 24))
        let counter = Counter()
        let existing = serversByAddress

        // Filtering and re-sorting thousands of rows is the expensive part, so the mod
        // sweep refreshes the table only once a second.
        startFlushLoop(interval: .seconds(1))
        await service.queryAll(addresses: pending, plan: plan, existing: existing) { [weak self] server in
            let done = await counter.increment()
            await MainActor.run {
                guard let self else { return }
                self.enqueue(server)
                if done % 64 == 0 { self.phase = .readingMods(done: done, total: total) }
            }
        }
        stopFlushLoop()
        flushPending()

        guard !Task.isCancelled else { return }
        phase = .finished(count: responsiveCount)
    }

    /// Results arrive faster than SwiftUI can usefully redraw, so they are batched.
    private func enqueue(_ server: GameServer) {
        pendingResults.append(server)
        if pendingResults.count >= 600 { flushPending() }
    }

    private func flushPending() {
        guard !pendingResults.isEmpty else { return }
        for server in pendingResults { serversByAddress[server.address] = server }
        pendingResults.removeAll(keepingCapacity: true)
        rebuildDerived()
    }

    private func startFlushLoop(interval: Duration = .milliseconds(500)) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                self?.flushPending()
            }
        }
    }

    private func stopFlushLoop() {
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - Single-server operations

    /// Refreshes one server including its mod list and player list.
    @discardableResult
    func refreshDetails(
        for address: ServerAddress, settings: AppSettings
    ) async -> GameServer? {
        loadingRules.insert(address)
        defer { loadingRules.remove(address) }

        let plan = ServerQueryPlan(
            includePlayers: true,
            includeRules: true,
            timeout: .milliseconds(max(settings.queryTimeoutMilliseconds, 2_000)),
            retries: 2
        )
        let service = ServerQueryService()
        let updated = await service.query(
            address: address, plan: plan, existing: serversByAddress[address]
        )
        serversByAddress[address] = updated
        rebuildDerived()
        return updated
    }

    /// Fetches mod lists for a batch of servers — used by the "load all mod lists" action.
    func loadModLists(for addresses: [ServerAddress], settings: AppSettings) async {
        let plan = ServerQueryPlan(
            includePlayers: false,
            includeRules: true,
            timeout: .milliseconds(max(settings.queryTimeoutMilliseconds, 2_000))
        )
        let service = ServerQueryService(concurrency: min(settings.queryConcurrency, 48))
        let existing = serversByAddress
        startFlushLoop()
        await service.queryAll(addresses: addresses, plan: plan, existing: existing) { [weak self] server in
            await MainActor.run { self?.enqueue(server) }
        }
        stopFlushLoop()
        flushPending()
    }

    /// Inserts or replaces a server in the list without going through the network.
    func upsert(_ server: GameServer) {
        serversByAddress[server.address] = server
        rebuildDerived()
    }

    /// Adds a server by `host:port`, querying it immediately.
    @discardableResult
    func addDirect(_ text: String, settings: AppSettings) async -> GameServer? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        guard let host = parts.first.map(String.init), !host.isEmpty else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 2_302 : 2_302
        let address = ServerAddress(host: host, gamePort: port)
        let server = await refreshDetails(for: address, settings: settings)
        if server?.queryFailed == false { selection = address }
        return server
    }

    // MARK: - Favourites and history

    func isFavourite(_ server: GameServer) -> Bool {
        favourites.contains(server.address.description)
    }

    func toggleFavourite(_ server: GameServer) {
        let key = server.address.description
        if favourites.contains(key) { favourites.remove(key) } else { favourites.insert(key) }
    }

    func noteJoined(_ server: GameServer) {
        let key = server.address.description
        recents.removeAll { $0 == key }
        recents.insert(key, at: 0)
        if recents.count > 25 { recents.removeLast(recents.count - 25) }
    }
}

/// Actor-isolated counter so progress can be tallied from the query task group.
private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
