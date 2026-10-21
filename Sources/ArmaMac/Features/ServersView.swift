import SwiftUI

/// Community server browser: master-server list, live A2S queries, filters, and one-click
/// join with automatic mod resolution.
struct ServersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.windowWidth) private var windowWidth
    @State private var showInspector = true
    /// What the user last chose, so the inspector comes back when there is room again.
    @State private var wantsInspector = true
    @State private var directAddress = ""
    @State private var showDirectConnect = false

    private var browser: ServerBrowserModel { app.browser }

    /// The sidebar, the list's minimum width and the inspector together need roughly this
    /// much: a 205pt sidebar, roughly 340pt of usable list, and the inspector at its 230pt
    /// minimum. Below that it would hang off the window's edge.
    private var hasRoomForInspector: Bool { windowWidth >= 900 }

    /// Roughly how much width the list column actually gets. The filter bar's controls are
    /// `fixedSize`, so they must pick their density from this rather than from the whole
    /// window — sizing them against the window made the bar wider than its own column,
    /// which crushed the sidebar and pushed the inspector off the window's edge.
    private var listWidth: CGFloat {
        windowWidth - 205 - (showInspector ? 280 : 0)
    }

    /// `showInspector` is derived, never set directly — writing it from the toolbar button
    /// as well let the two disagree, which is how the inspector ended up open on a window
    /// too narrow to hold it.
    private func syncInspector() {
        let shouldShow = wantsInspector && hasRoomForInspector
        if showInspector != shouldShow { showInspector = shouldShow }
    }

    var body: some View {
        @Bindable var browser = app.browser

        serverList
            // Without an explicit floor the layout takes the rows' intrinsic width as the
            // list's minimum, which is wide enough to squeeze the sidebar below its own
            // minimum and push the inspector off the window's right edge.
            .frame(minWidth: 320)
            .safeAreaInset(edge: .top, spacing: 0) { filterBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .inspector(isPresented: $showInspector) {
                ServerInspector(server: browser.selectedServer)
                    .inspectorColumnWidth(min: 230, ideal: 280, max: 400)
            }
            .searchable(
                text: $browser.filter.searchText,
                placement: .toolbar,
                prompt: "Search servers, maps, addresses"
            )
            .toolbar { toolbarContent }
            .sheet(isPresented: $showDirectConnect) { directConnectSheet }
            .onChange(of: windowWidth, initial: true) { _, _ in syncInspector() }
            .onChange(of: wantsInspector) { _, _ in syncInspector() }
    }

    // MARK: - List

    private var serverList: some View {
        @Bindable var browser = app.browser

        return List(selection: $browser.selection) {
            ForEach(browser.visibleServers) { server in
                ServerCard(
                    server: server,
                    isFavourite: browser.isFavourite(server),
                    isLoadingMods: browser.loadingRules.contains(server.address),
                    installedMods: browser.installedWorkshopIDs,
                    toggleFavourite: { browser.toggleFavourite(server) }
                )
                .tag(server.address)
                .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                .contentShape(Rectangle())
                // A tap gesture on a row swallows the click AppKit's table would have
                // turned into a selection, so the single click has to set it by hand.
                // The double-click handler must be declared first to win the race.
                .onTapGesture(count: 2) {
                    browser.selection = server.address
                    Task { await app.prepareJoin(server: server) }
                }
                .onTapGesture { browser.selection = server.address }
                .contextMenu { contextMenu(for: [server.address]) }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .overlay {
            if browser.serversByAddress.isEmpty {
                emptyState
            } else if browser.visibleServers.isEmpty {
                noMatchesState
            }
        }
    }

    /// Servers exist but the filters hide them all — say so instead of showing a blank list.
    private var noMatchesState: some View {
        @Bindable var browser = app.browser

        return EmptyStateView(
            title: "No servers match",
            message: browser.filter.searchText.isEmpty
                ? "\(browser.serversByAddress.count) servers are loaded, but your filters exclude every one."
                : "Nothing matches “\(browser.filter.searchText)” with the current filters.",
            systemImage: "line.3.horizontal.decrease.circle",
            actionTitle: "Reset filters",
            action: { browser.filter = ServerFilter() }
        )
        .background(.background)
    }

    @ViewBuilder
    private func contextMenu(for addresses: Set<ServerAddress>) -> some View {
        let servers = addresses.compactMap { browser.serversByAddress[$0] }

        Button("Join") {
            guard let server = servers.first else { return }
            Task { await app.prepareJoin(server: server) }
        }
        .disabled(servers.count != 1)

        Button("Load mod list") {
            Task {
                await browser.loadModLists(
                    for: servers.map(\.address), settings: app.settings
                )
            }
        }

        Button(installMissingTitle(for: servers.first)) {
            guard let server = servers.first else { return }
            let installed = browser.installedWorkshopIDs
            let missing = server.mods.filter { !installed.contains($0.publishedFileID) }
            app.download(
                ids: missing.map(\.publishedFileID),
                names: Dictionary(
                    missing.map { ($0.publishedFileID, $0.name) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
        .disabled(missingModCount(for: servers.first) == 0)

        Button("Use this server's mods") {
            guard let server = servers.first else { return }
            Task {
                let refreshed = server.modsLoaded
                    ? server
                    : (await browser.refreshDetails(for: server.address, settings: app.settings) ?? server)
                app.applyServerModSelection(refreshed)
            }
        }
        .disabled(servers.count != 1)

        Divider()

        Button(servers.allSatisfy(browser.isFavourite) ? "Remove from favourites" : "Add to favourites") {
            for server in servers { browser.toggleFavourite(server) }
        }

        Button("Export modset…") {
            guard let server = servers.first else { return }
            exportModset(of: server)
        }
        .disabled(servers.first.map { !$0.modsLoaded || $0.mods.isEmpty } ?? true)

        Button("Copy address") {
            app.copyToPasteboard(servers.map(\.address.description).joined(separator: "\n"))
        }

        Button("Open in Steam") {
            guard let url = servers.first?.steamConnectURL else { return }
            app.openInSteam(url)
        }
        .disabled(servers.count != 1)
    }

    /// Writes a server's modset as an Arma 3 Launcher preset, shareable with anyone.
    private func exportModset(of server: GameServer) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(server.displayName).html"
        panel.message = "Save this server's mod list as a preset"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = PresetHTML.export(name: server.displayName, serverMods: server.mods)
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    /// How many of a server's mods are not installed locally.
    private func missingModCount(for server: GameServer?) -> Int {
        guard let server, server.modsLoaded else { return 0 }
        let installed = browser.installedWorkshopIDs
        return server.mods.count { !installed.contains($0.publishedFileID) }
    }

    private func installMissingTitle(for server: GameServer?) -> String {
        let count = missingModCount(for: server)
        return count == 0 ? "No mods to install" : "Install \(count) missing mods"
    }

    @ViewBuilder
    private var emptyState: some View {
        if browser.isRefreshing {
            EmptyStateView(
                title: "Fetching servers…",
                message: "Pulling the Arma 3 list, then querying each server for players, mods and ping.",
                systemImage: "server.rack"
            )
            .background(.background)
        } else if !browser.canFetchFullList(settings: app.settings) {
            apiKeyOnboarding
        } else {
            EmptyStateView(
                title: "No servers loaded",
                message: "Refresh to pull the community server list.",
                systemImage: "server.rack",
                actionTitle: "Refresh",
                action: { browser.refresh(settings: app.settings) }
            )
            .background(.background)
        }
    }

    /// Shown when no source for the community list is available — which in practice means
    /// Steam is not running or Arma is not installed.
    private var apiKeyOnboarding: some View {
        VStack(spacing: 14) {
            Image(systemName: "powerplug")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Start Steam to load servers")
                .font(.title3.weight(.medium))
            Text("""
            ArmaMac reads the community server list straight from your running Steam client — \
            the same list Steam's own server browser shows, with no API key needed. Sign in to \
            Steam, then refresh.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)

            Button("Refresh") { browser.refresh(settings: app.settings) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Divider().frame(width: 320).padding(.vertical, 4)

            Text("Favourites, recent servers and direct connections work either way.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Add a server by address") { showDirectConnect = true }
                Button("Refresh my servers") {
                    browser.refreshKnownServers(settings: app.settings)
                }
                .disabled(browser.favourites.isEmpty && browser.recents.isEmpty)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(.background)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        @Bindable var browser = app.browser

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                scopeControl

                Divider().frame(height: 16)

                sortMenu
                filtersMenu

                Spacer(minLength: 4)

                if listWidth >= 700 {
                    Text(browser.sortSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, alignment: .trailing)
                        .layoutPriority(-1)
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Divider()
        }
        .background(.bar)
    }

    /// Picks its density from the width the column actually has. `ViewThatFits` cannot be
    /// used here: inside an `HStack` it is proposed an unconstrained width and always takes
    /// the widest option, which pushed the whole table off the left edge.
    private var scopeControl: some View {
        @Bindable var browser = app.browser

        return Group {
            if listWidth >= 800 {
                Picker("", selection: $browser.filter.scope) {
                    ForEach(ServerFilter.Scope.allCases) { scope in
                        Label(scope.displayName, systemImage: scope.symbol).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if listWidth >= 400 {
                Picker("", selection: $browser.filter.scope) {
                    ForEach(ServerFilter.Scope.allCases) { scope in
                        Image(systemName: scope.symbol).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Menu {
                    Picker("Scope", selection: $browser.filter.scope) {
                        ForEach(ServerFilter.Scope.allCases) { scope in
                            Label(scope.displayName, systemImage: scope.symbol).tag(scope)
                        }
                    }
                } label: {
                    Image(systemName: browser.filter.scope.symbol)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    /// Builds the sort chain: a primary column plus up to two tie-breakers.
    private var sortMenu: some View {
        @Bindable var browser = app.browser

        return Menu {
            ForEach(0..<ServerBrowserModel.maxSortLevels, id: \.self) { level in
                let heading = level == 0 ? "Sort by" : (level == 1 ? "Then by" : "And then by")
                // Only offer the next level once the one above it is set.
                if level == 0 || browser.sortField(atLevel: level - 1) != nil {
                    Section(heading) {
                        Picker(heading, selection: fieldBinding(level: level)) {
                            if level > 0 { Text("None").tag(ServerSortField?.none) }
                            ForEach(ServerSortField.allCases) { field in
                                Text(field.title).tag(ServerSortField?.some(field))
                            }
                        }
                        if let field = browser.sortField(atLevel: level) {
                            Picker("Direction", selection: directionBinding(level: level)) {
                                Text(field.directionLabel(ascending: false)).tag(false)
                                Text(field.directionLabel(ascending: true)).tag(true)
                            }
                        }
                    }
                }
            }

            Divider()

            Section("Presets") {
                Button("Busiest playable") {
                    browser.sortRules = [
                        ServerSortRule(field: .players, ascending: false),
                        ServerSortRule(field: .ping, ascending: true),
                    ]
                }
                Button("Closest first") {
                    browser.sortRules = [
                        ServerSortRule(field: .ping, ascending: true),
                        ServerSortRule(field: .players, ascending: false),
                    ]
                }
                Button("Room to join") {
                    browser.sortRules = [
                        ServerSortRule(field: .freeSlots, ascending: false),
                        ServerSortRule(field: .players, ascending: false),
                        ServerSortRule(field: .ping, ascending: true),
                    ]
                }
                Button("Vanilla first") {
                    browser.sortRules = [
                        ServerSortRule(field: .mods, ascending: true),
                        ServerSortRule(field: .players, ascending: false),
                    ]
                }
                Button("By name") {
                    browser.sortRules = [ServerSortRule(field: .name, ascending: true)]
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sorting by \(browser.sortSummary)")
    }

    private func fieldBinding(level: Int) -> Binding<ServerSortField?> {
        Binding(
            get: { app.browser.sortField(atLevel: level) },
            set: { app.browser.setSortField($0, atLevel: level) }
        )
    }

    private func directionBinding(level: Int) -> Binding<Bool> {
        Binding(
            get: { app.browser.sortAscending(atLevel: level) },
            set: { app.browser.setSortAscending($0, atLevel: level) }
        )
    }

    /// All the boolean and range filters, gathered so the bar stays readable.
    private var filtersMenu: some View {
        @Bindable var browser = app.browser

        return Menu {
            Section("Show only") {
                Toggle("Not empty", isOn: $browser.filter.hideEmpty)
                Toggle("Not full", isOn: $browser.filter.hideFull)
                Toggle("No password", isOn: $browser.filter.hidePasswordProtected)
                Toggle("BattlEye", isOn: $browser.filter.requireBattlEye)
                Toggle("Mods I already have", isOn: $browser.filter.onlyInstalledMods)
            }
            Section("Mods") {
                Picker("Mods", selection: $browser.filter.modFilter) {
                    ForEach(ServerFilter.ModFilter.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }
            Section("Limits") {
                Picker("Max ping", selection: $browser.filter.maxPingMilliseconds) {
                    Text("Any").tag(Int?.none)
                    Text("50 ms").tag(Int?.some(50))
                    Text("100 ms").tag(Int?.some(100))
                    Text("200 ms").tag(Int?.some(200))
                }
                Picker("Minimum players", selection: $browser.filter.minPlayers) {
                    Text("Any").tag(Int?.none)
                    Text("1+").tag(Int?.some(1))
                    Text("5+").tag(Int?.some(5))
                    Text("20+").tag(Int?.some(20))
                }
                if !browser.knownMaps.isEmpty {
                    Picker("Map", selection: $browser.filter.mapName) {
                        Text("Any").tag(String?.none)
                        ForEach(browser.knownMaps.prefix(40), id: \.self) { map in
                            Text(map).tag(String?.some(map))
                        }
                    }
                }
            }
            Divider()
            Button("Reset filters") { browser.filter = ServerFilter() }
        } label: {
            Label(activeFilterCount == 0 ? "Filters" : "Filters (\(activeFilterCount))",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// How many filters are narrowing the list, so the button can say so.
    private var activeFilterCount: Int {
        let filter = browser.filter
        var count = 0
        if filter.hideEmpty { count += 1 }
        if filter.hideFull { count += 1 }
        if filter.hidePasswordProtected { count += 1 }
        if filter.requireBattlEye { count += 1 }
        if filter.onlyInstalledMods { count += 1 }
        if filter.modFilter != .any { count += 1 }
        if filter.maxPingMilliseconds != nil { count += 1 }
        if filter.minPlayers != nil { count += 1 }
        if filter.mapName != nil { count += 1 }
        return count
    }

    // MARK: - Status bar

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                switch browser.phase {
                case .idle:
                    Text("Ready")
                case .fetchingList:
                    ProgressView().controlSize(.small)
                    Text("Fetching server list…")
                case let .querying(done, total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 140)
                    Text("Pinging \(done) of \(total)")
                case let .readingMods(done, total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 140)
                    Text("Reading mod lists \(done) of \(total)")
                case let .finished(count):
                    Text("\(count) servers responded")
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }

                Divider().frame(height: 12)
                Text("\(browser.visibleServers.count) shown")
                Text("\(browser.totalPlayers) players online")
                    .foregroundStyle(.secondary)
                    .layoutPriority(-1)

                Spacer(minLength: 4)

                if let last = browser.lastRefresh {
                    Text("Updated \(Format.relative(last))")
                        .foregroundStyle(.tertiary)
                        .layoutPriority(-2)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                if browser.isRefreshing {
                    browser.cancelRefresh()
                } else {
                    browser.refresh(settings: app.settings)
                }
            } label: {
                Label(
                    browser.isRefreshing ? "Stop" : "Refresh",
                    systemImage: browser.isRefreshing ? "stop.circle" : "arrow.clockwise"
                )
            }
            .help("Fetch the community server list (\u{2318}R)")
        }

        ToolbarItem {
            Menu {
                Button("Direct Connect…") { showDirectConnect = true }

                Divider()

                Button("Reload Mod Lists") {
                    Task {
                        await browser.loadModLists(
                            for: browser.visibleServers.map(\.address),
                            settings: app.settings
                        )
                    }
                }
                Button("Refresh Selected Server") {
                    guard let address = browser.selection else { return }
                    Task { await browser.refreshDetails(for: address, settings: app.settings) }
                }
                .disabled(browser.selection == nil)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem { DownloadsChip() }

        ToolbarItem {
            Button {
                guard let server = browser.selectedServer else { return }
                Task { await app.prepareJoin(server: server) }
            } label: {
                Label("Join", systemImage: "play.fill")
            }
            .disabled(browser.selectedServer == nil)
            .help("Match this server's mods and launch")
        }

        ToolbarItem {
            Button {
                wantsInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .disabled(!hasRoomForInspector)
            .help(
                hasRoomForInspector
                    ? "Show the selected server's details"
                    : "Widen the window to show details"
            )
        }
    }

    private var directConnectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Direct connect").font(.headline)
            Text("Enter the server's game address. The Steam query port is assumed to be one higher.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("host:port", text: $directAddress, prompt: Text("192.0.2.10:2302"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { showDirectConnect = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let text = directAddress
                    showDirectConnect = false
                    directAddress = ""
                    Task { await browser.addDirect(text, settings: app.settings) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(directAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
