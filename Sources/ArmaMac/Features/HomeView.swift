import SwiftUI

/// Dashboard: what the launcher is about to start, anything that needs attention before it
/// will work, and one click back into the servers and modsets actually in use.
///
/// The Play control lives permanently in the launch bar, so this page does not repeat the
/// mode-picking ceremony — it reports state and offers the shortcuts that state implies.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.windowWidth) private var windowWidth
    var onOpenSection: (AppTab) -> Void = { _ in }

    @State private var showSavePreset = false
    @State private var presetName = ""

    /// Below this the two card columns start squeezing their contents, so they stack.
    private var isWide: Bool { windowWidth >= 940 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                hero
                attentionStack
                if app.installations.isEmpty {
                    noInstallCard
                } else {
                    cardColumns
                    communityCard
                }
            }
            .padding(18)
            .frame(maxWidth: 1_020, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .sheet(isPresented: $showSavePreset) { savePresetSheet }
    }

    // MARK: - Hero

    private var hero: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    appGlyph

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arma 3").font(.title3.weight(.semibold))
                        Text(runtimeSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("Profile \(app.activeProfileName) · \(loadoutSummary)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    readinessChip
                }

                heroActions
            }
        }
    }

    private var appGlyph: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: "scope")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    @ViewBuilder
    private var heroActions: some View {
        HStack(spacing: 8) {
            if app.isGameRunning {
                Button {
                    app.focusRunningGame()
                } label: {
                    Label("Bring Arma to front", systemImage: "arrow.up.forward.app.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    app.launch()
                } label: {
                    Label("Play \(app.settings.launchMode.title)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(app.settings.launchMode == .vanilla ? Color.accentColor : .green)
                .disabled(!app.canLaunch)
            }

            if let server = resumeServer {
                Button {
                    Task { await app.prepareJoin(server: server) }
                } label: {
                    Label {
                        // Server names run long enough to reflow the whole row, so this one
                        // is capped and clipped; the full name is in the tooltip.
                        Text("Rejoin \(server.displayName)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 190, alignment: .leading)
                    } icon: {
                        Image(systemName: "arrow.uturn.right")
                    }
                }
                .help("Rejoin \(server.displayName)")
            }

            Button {
                onOpenSection(.servers)
            } label: {
                Label("Browse servers", systemImage: "server.rack")
            }

            Spacer(minLength: 0)
        }
        .controlSize(.large)
    }

    private var readinessChip: some View {
        let (text, tint): (String, Color) =
            if app.isGameRunning { ("Running", .green) }
            else if !app.canLaunch { ("No install", .orange) }
            else if !attentionItems.isEmpty { ("Needs attention", .orange) }
            else { ("Ready", .green) }

        return HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    /// Which install and executable a launch would actually use.
    private var runtimeSummary: String {
        guard let installation = app.selectedInstallation else { return "No installation found" }
        guard let executable = installation.executable(
            battlEye: app.settings.launchOptions.useBattlEye,
            prefer64Bit: app.settings.launchOptions.prefer64Bit
        ) else { return installation.library.displayName }
        return "\(installation.library.displayName) · \(executable.kind.displayName)"
    }

    /// What a launch would load right now, in one phrase.
    private var loadoutSummary: String {
        guard app.settings.launchMode == .modded else { return "Vanilla" }
        let count = app.library.enabledMods.count
        return switch count {
        case 0: "No mods enabled"
        case 1: "1 mod"
        default: "\(count) mods"
        }
    }

    /// The server the Rejoin shortcut points at — the last one joined, even if the browser
    /// has not been refreshed yet this session.
    private var resumeServer: GameServer? {
        app.browser.recents.first.flatMap(server(forKey:))
    }

    // MARK: - Attention

    @ViewBuilder
    private var attentionStack: some View {
        let items = attentionItems
        if !items.isEmpty {
            VStack(spacing: 8) {
                ForEach(items) { AttentionRow(item: $0) }
            }
        }
    }

    /// Everything standing between the user and a working launch, worst first. An empty
    /// result is the normal state and draws nothing.
    private var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []

        if app.installations.isEmpty {
            items.append(
                AttentionItem(
                    id: "install",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "No Arma 3 installation found",
                    message: "Nothing can launch until one is detected.",
                    actionTitle: "Search again",
                    action: { Task { await app.detectInstallations(); await app.rescanMods() } }
                )
            )
        }

        let missing = app.library.missingEnabledIDs
        if !missing.isEmpty {
            items.append(
                AttentionItem(
                    id: "missing",
                    symbol: "questionmark.folder",
                    tint: .orange,
                    title: "\(missing.count) mods in your load order are not installed",
                    message: "They will be skipped, which usually means a failed join.",
                    actionTitle: "Open Mods",
                    action: { onOpenSection(.mods) }
                )
            )
        }

        if app.downloader.isRunning {
            let percent = Int((app.downloader.overallProgress * 100).rounded())
            items.append(
                AttentionItem(
                    id: "downloads",
                    symbol: "arrow.down.circle.fill",
                    tint: .blue,
                    title: "Downloading \(app.downloader.items.count) Workshop items",
                    message: "\(percent)% complete · \(Format.bytes(app.downloader.downloadedBytes)) of \(Format.bytes(app.downloader.expectedBytes))"
                )
            )
        }

        let outdated = app.library.outdatedMods
        if !outdated.isEmpty {
            items.append(
                AttentionItem(
                    id: "outdated",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .blue,
                    title: "\(outdated.count) Workshop mods have updates",
                    message: outdated.prefix(3).map(\.name).joined(separator: ", "),
                    actionTitle: "Update all",
                    action: { app.updateOutdatedMods() }
                )
            )
        }

        if app.selectedInstallation?.battlEyeUnavailable(for: app.settings.launchOptions) == true {
            items.append(
                AttentionItem(
                    id: "battleye",
                    symbol: "shield.slash",
                    tint: .orange,
                    title: "BattlEye is not available for this executable",
                    message: "Servers that require it will refuse the connection."
                )
            )
        }

        if let status = app.statusMessage {
            items.append(
                AttentionItem(
                    id: "status", symbol: "info.circle.fill", tint: .secondary,
                    title: status, message: ""
                )
            )
        }

        return items
    }

    // MARK: - Card layout

    @ViewBuilder
    private var cardColumns: some View {
        if isWide {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    loadoutCard
                    presetsCard
                }
                VStack(spacing: 14) {
                    recentServersCard
                    favouritesCard
                }
            }
        } else {
            VStack(spacing: 14) {
                loadoutCard
                recentServersCard
                presetsCard
                favouritesCard
            }
        }
    }

    private func cardHeader(
        _ title: String,
        symbol: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 6)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    // MARK: - Loadout

    private var loadoutCard: some View {
        @Bindable var app = app

        return DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("Loadout", symbol: "slider.horizontal.3",
                           actionTitle: "Manage") { onOpenSection(.mods) }

                Picker("", selection: $app.settings.launchMode) {
                    ForEach(LaunchMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                loadoutBody

                HStack(spacing: 12) {
                    Button("Save as preset…") {
                        presetName = ""
                        showSavePreset = true
                    }
                    .disabled(app.library.enabledIDs.isEmpty)

                    if app.library.canRestorePreviousOrder {
                        Button("Undo \(app.library.previousOrderSource ?? "last change")") {
                            app.restorePreviousLoadOrder()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.link)
                .font(.callout)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var loadoutBody: some View {
        if app.settings.launchMode == .vanilla {
            captionRow(
                "Base game and official DLC only. Works on any vanilla server, starts fastest."
            )
        } else if app.library.enabledMods.isEmpty {
            captionRow("Nothing enabled yet — pick mods in the Mods tab to build a load order.")
        } else {
            let mods = app.library.enabledMods
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(mods.prefix(5).enumerated()), id: \.element.id) { index, mod in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        Text(mod.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        ModOriginBadge(origin: mod.origin)
                    }
                }
                if mods.count > 5 {
                    Text("+ \(mods.count - 5) more in the load order")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 21)
                }
                Text("\(mods.count) mods · \(Format.bytes(app.library.enabledSizeOnDisk)) on disk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Servers

    private var recentServersCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader("Jump back in", symbol: "clock.arrow.circlepath",
                           actionTitle: "Browse") { onOpenSection(.servers) }

                let recents = app.browser.recents.prefix(5).compactMap(server(forKey:))
                if recents.isEmpty {
                    captionRow("Servers you join show up here, ready to rejoin in one click.")
                } else {
                    ForEach(recents) { serverRow($0) }
                }
            }
        }
    }

    @ViewBuilder
    private var favouritesCard: some View {
        let favourites = app.browser.favourites.sorted().prefix(5).compactMap(server(forKey:))
        if !favourites.isEmpty {
            DashboardCard {
                VStack(alignment: .leading, spacing: 8) {
                    cardHeader("Favourites", symbol: "star.fill",
                               actionTitle: "Refresh") {
                        app.browser.refreshKnownServers(settings: app.settings)
                    }
                    ForEach(favourites) { serverRow($0) }
                }
            }
        }
    }

    /// Resolves a stored `host:port` key. Servers that have never been queried still get a
    /// row — joining one queries it on the spot.
    private func server(forKey key: String) -> GameServer? {
        guard let address = ServerBrowserModel.parseAddress(key) else { return nil }
        return app.browser.serversByAddress[address] ?? GameServer(address: address)
    }

    private func serverRow(_ server: GameServer) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(server.map.isEmpty ? server.address.description : server.map)
                    if server.maxPlayers > 0 {
                        Text("·")
                        Text("\(server.players)/\(server.maxPlayers)").monospacedDigit()
                    }
                    if server.modsLoaded, !server.mods.isEmpty {
                        Text("·")
                        Text("\(server.mods.count) mods")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            PingBadge(ping: server.ping).font(.caption)

            Button {
                Task { await app.prepareJoin(server: server) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Match this server's mods and join")
        }
        .padding(.vertical, 1)
    }

    // MARK: - Presets

    private var presetsCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader("Presets", symbol: "bookmark.fill",
                           actionTitle: "Manage") { onOpenSection(.mods) }

                if app.settings.presets.isEmpty {
                    captionRow("Save a load order as a preset to switch modsets in one click.")
                } else {
                    ForEach(app.settings.presets.prefix(5)) { preset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name).font(.callout).lineLimit(1)
                                HStack(spacing: 5) {
                                    Text("\(preset.modIDs.count) mods")
                                    if let source = preset.sourceServer {
                                        Text("·")
                                        Text(source).lineLimit(1)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            Button("Apply") {
                                app.applyPreset(preset)
                                app.settings.launchMode = .modded
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save preset").font(.headline)
            Text("Stores the \(app.library.enabledIDs.count) mods currently in your load order, in order.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            HStack {
                Spacer()
                Button("Cancel") { showSavePreset = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.savePreset(named: presetName.trimmingCharacters(in: .whitespaces))
                    showSavePreset = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Community

    private var communityCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(
                    "Community",
                    symbol: "antenna.radiowaves.left.and.right",
                    actionTitle: app.browser.isRefreshing ? nil : "Refresh"
                ) {
                    app.browser.refresh(settings: app.settings)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    StatTile(
                        value: app.browser.serversByAddress.isEmpty
                            ? "—" : "\(app.browser.responsiveCount)",
                        label: "Servers online",
                        symbol: "server.rack",
                        tint: .green
                    ) { onOpenSection(.servers) }

                    StatTile(
                        value: app.browser.totalPlayers > 0 ? "\(app.browser.totalPlayers)" : "—",
                        label: "Players online",
                        symbol: "person.2.fill",
                        tint: .orange
                    ) { onOpenSection(.servers) }

                    StatTile(
                        value: "\(app.library.mods.count)",
                        label: "Mods installed",
                        symbol: "shippingbox.fill",
                        tint: .blue
                    ) { onOpenSection(.mods) }

                    StatTile(
                        value: "\(app.library.enabledIDs.count)",
                        label: "In load order",
                        symbol: "list.number",
                        tint: .purple
                    ) { onOpenSection(.mods) }
                }

                HStack(spacing: 6) {
                    if app.browser.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text(refreshStatus)
                    } else if app.browser.lastRefresh == nil {
                        Text("The server list has not been fetched yet this session.")
                    } else {
                        Text("Updated \(Format.relative(app.browser.lastRefresh))")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var refreshStatus: String {
        switch app.browser.phase {
        case .fetchingList: "Fetching the server list…"
        case let .querying(done, total): "Pinging \(done) of \(total)"
        case let .readingMods(done, total): "Reading mod lists \(done) of \(total)"
        default: "Refreshing…"
        }
    }

    // MARK: - Shared pieces

    private func captionRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private var noInstallCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("Where ArmaMac looks", symbol: "magnifyingglass")
                Text("""
                The native Steam library, plus Steam installs inside CrossOver and Whisky \
                bottles. If Arma 3 lives somewhere else, add that folder in Settings.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Search again") {
                    Task { await app.detectInstallations(); await app.rescanMods() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Building blocks

/// Shared container for the dashboard's panels.
private struct DashboardCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassPanel(cornerRadius: 12)
    }
}

/// One thing standing between the user and a working launch.
private struct AttentionItem: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
}

private struct AttentionRow: View {
    let item: AttentionItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 15))
                .foregroundStyle(item.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if !item.message.isEmpty {
                    Text(item.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if let actionTitle = item.actionTitle, let action = item.action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(item.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(item.tint.opacity(0.25), lineWidth: 1)
        )
    }
}

/// Compact clickable metric used in the dashboard's stats grid.
private struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 19, weight: .semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.quaternary.opacity(isHovering ? 0.55 : 0.32))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
