import AppKit
import Foundation
import Observation

/// Root coordinator: owns settings, the detected installs, the mod library, the server
/// browser and the download queue, and implements the flows that span them.
@MainActor
@Observable
final class AppModel {
    // MARK: - State

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.scheduleSave(settings)
        }
    }

    private(set) var installations: [GameInstallation] = []
    private(set) var libraries: [SteamLibrary] = []
    var selectedInstallation: GameInstallation? {
        didSet {
            settings.selectedInstallationPath = selectedInstallation?
                .directory.path(percentEncoded: false)
        }
    }

    let library = ModLibraryModel()
    let gameSettings = GameSettingsModel()
    let browser = ServerBrowserModel()
    let downloader = WorkshopDownloader()

    private(set) var isBootstrapped = false
    private(set) var runningProcess: Process?
    var statusMessage: String?
    var alert: AlertPayload?
    /// Pending "this server needs mods you do not have" prompt.
    var pendingJoin: PendingJoin?

    private let store = SettingsStore()
    private let locator = SteamLocator()
    private let launcher = GameLauncher()

    struct AlertPayload: Identifiable {
        var id = UUID()
        var title: String
        var message: String
        var isError = true
    }

    struct PendingJoin: Identifiable {
        var id: ServerAddress { server.address }
        var server: GameServer
        var missing: [ServerMod]
        var present: [ServerMod]
        /// The server never answered the mod-list query, so we cannot tell what it needs.
        var modListUnavailable = false
        var retryFailed = false
        var password: String = ""
    }

    init() {
        self.settings = store.load()
    }

    // MARK: - Startup

    func bootstrap() async {
        guard !isBootstrapped else { return }
        isBootstrapped = true
        installTerminationHandler()
        observeGameLifecycle()

        // A finished download changes what is on disk, so rescan instead of making the
        // user press Rescan before their new mods show up.
        downloader.onFinished = { [weak self] in
            Task { @MainActor in
                await self?.rescanMods()
                self?.downloadsFinished()
            }
        }

        library.enabledIDs = settings.enabledModIDs
        browser.favourites = Set(settings.favouriteServers)
        browser.recents = settings.recentServers
        browser.filter.hideEmpty = settings.hideEmptyServers
        browser.filter.hideFull = settings.hideFullServers
        browser.filter.hidePasswordProtected = settings.hidePasswordProtected
        if !settings.sortRules.isEmpty { browser.sortRules = settings.sortRules }

        await detectInstallations()
        await rescanMods()

        if settings.autoRefreshOnOpen {
            browser.refresh(settings: settings)
        }
    }

    /// Saves settings synchronously when the app quits.
    ///
    /// Writes are debounced, so without this anything changed in the last fraction of a
    /// second — a tab switch, a favourite, a newly enabled mod — dies with the process.
    private func installTerminationHandler() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.save(self.settings)
            }
        }
    }

    /// Rescans the filesystem for Steam libraries and Arma installs.
    func detectInstallations() async {
        let locator = self.locator
        let found = await Task.detached(priority: .userInitiated) {
            let libraries = locator.discoverLibraries()
            return (libraries, locator.discoverInstallations(in: libraries))
        }.value

        libraries = found.0
        installations = found.1
        // The Steam client route needs libsteam_api.dylib, which ships with the game.
        let dylib = SteamClientServerList.locateDylib(installations: installations)
        browser.steamDylib = dylib
        downloader.steamDylib = dylib

        if let saved = settings.selectedInstallationPath,
           let match = installations.first(where: {
               $0.directory.path(percentEncoded: false) == saved
           }) {
            selectedInstallation = match
        } else {
            selectedInstallation = installations.first
        }

        gameSettings.refresh(installation: selectedInstallation)
        refreshGameRunning()

        if installations.isEmpty {
            statusMessage = "No Arma 3 install found. Add one in Settings."
        } else {
            statusMessage = nil
        }
    }

    func rescanMods() async {
        await library.scan(
            installation: selectedInstallation,
            extraDirectories: settings.extraModDirectories.map { URL(filePath: $0) },
            includeOfficial: settings.showOfficialMods
        )
        browser.installedWorkshopIDs = Set(library.mods.compactMap(\.publishedFileID))
        persistModSelection()
    }

    // MARK: - Persistence bridges

    /// The sub-models own their own state; mirror the persistent parts back into settings.
    func persistModSelection() {
        settings.enabledModIDs = library.enabledIDs
    }

    func persistBrowserState() {
        settings.favouriteServers = Array(browser.favourites).sorted()
        settings.recentServers = browser.recents
        settings.hideEmptyServers = browser.filter.hideEmpty
        settings.hideFullServers = browser.filter.hideFull
        settings.hidePasswordProtected = browser.filter.hidePasswordProtected
        settings.sortRules = browser.sortRules
    }

    // MARK: - Launching

    var canLaunch: Bool { selectedInstallation != nil }

    /// The mods a launch in `mode` would load.
    func mods(for mode: LaunchMode) -> [Mod] {
        mode == .vanilla ? [] : library.enabledMods
    }

    /// Builds the plan the Play button would run, for preview in the UI.
    func previewPlan(mode: LaunchMode? = nil, connect: ConnectTarget? = nil) -> LaunchPlan? {
        guard let installation = selectedInstallation else { return nil }
        let mods = mods(for: mode ?? settings.launchMode)
        return try? launcher.makePlan(
            installation: installation,
            mods: mods,
            options: settings.launchOptions,
            connect: connect,
            // The links are only made at launch, so predict them — otherwise the command
            // shown here is not the command that runs.
            linkedMods: settings.linkWorkshopMods
                ? ModLinker(installation: installation).plannedLinks(for: mods)
                : [:]
        )
    }

    @discardableResult
    func launch(mode: LaunchMode? = nil, connect: ConnectTarget? = nil) -> Bool {
        guard let installation = selectedInstallation else {
            alert = AlertPayload(
                title: "No Arma 3 install",
                message: GameLauncher.LaunchError.noInstallation.localizedDescription
            )
            return false
        }

        // Steam treats an open API session as "the game is running", which confuses the
        // real launch, so close ours first.
        downloader.releaseSteamSession()

        let mods = mods(for: mode ?? settings.launchMode)
        var linked: [String: URL] = [:]

        if settings.linkWorkshopMods, mods.contains(where: { $0.origin == .workshop }) {
            do {
                let linker = ModLinker(installation: installation)
                linked = try linker.synchronise(mods: mods).linked
            } catch {
                alert = AlertPayload(
                    title: "Could not prepare mods",
                    message: error.localizedDescription
                        + "\n\nThe game can still start with absolute mod paths."
                )
            }
        }

        do {
            let plan = try launcher.makePlan(
                installation: installation,
                mods: mods,
                options: settings.launchOptions,
                connect: connect,
                linkedMods: linked
            )
            runningProcess = try launcher.launch(
                plan: plan,
                viaSteam: settings.launchThroughSteam
            ) { message in
                Task { @MainActor [weak self] in
                    self?.alert = AlertPayload(title: "Launch failed", message: message)
                    self?.statusMessage = nil
                }
            }
            statusMessage = connect.map { "Launching and connecting to \($0.address)…" }
                ?? "Launching Arma 3…"
            refreshGameRunning()
            return true
        } catch {
            alert = AlertPayload(title: "Launch failed", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Joining a server

    /// Works out what a server needs, then either joins straight away or raises the
    /// "missing mods" prompt.
    func prepareJoin(server: GameServer) async {
        var target = server
        if !target.modsLoaded {
            statusMessage = "Reading \(server.displayName)'s mod list…"
            target = await browser.refreshDetails(for: server.address, settings: settings) ?? server
        }
        statusMessage = nil

        // A failed rules query looks exactly like a vanilla server — both report no mods.
        // Launching on that assumption drops the player into a modded server with nothing
        // loaded, so ask instead of guessing.
        guard target.modsLoaded else {
            pendingJoin = PendingJoin(
                server: target, missing: [], present: [], modListUnavailable: true
            )
            return
        }

        let installed = Set(library.mods.compactMap(\.publishedFileID))
        let missing = target.mods.filter { !installed.contains($0.publishedFileID) }
        let present = target.mods.filter { installed.contains($0.publishedFileID) }

        guard missing.isEmpty else {
            let pending = PendingJoin(server: target, missing: missing, present: present)
            pendingJoin = pending
            // The sheet still comes up — it is where the progress lives — but nothing has
            // to be clicked: Steam is asked for the mods straight away and the join
            // continues on its own once they land.
            if settings.autoInstallServerMods, !downloader.isRunning {
                downloadMissingMods(for: pending, joinWhenReady: true)
            }
            return
        }

        applyServerModSelection(target)
        if target.isPasswordProtected {
            pendingJoin = PendingJoin(server: target, missing: [], present: present)
            return
        }
        join(server: target, password: nil)
    }

    /// Re-runs the mod-list query for the server in the join sheet.
    func retryModList() async {
        guard let join = pendingJoin else { return }
        let refreshed = await browser.refreshDetails(
            for: join.server.address, settings: settings
        )
        guard let refreshed, refreshed.modsLoaded else {
            pendingJoin?.retryFailed = true
            return
        }
        pendingJoin = nil
        await prepareJoin(server: refreshed)
    }

    /// Switches the enabled mods to exactly what the server runs, keeping the server's order.
    func applyServerModSelection(_ server: GameServer) {
        var ids: [String] = []
        for entry in server.mods {
            if let mod = library.mod(publishedFileID: entry.publishedFileID) {
                ids.append(mod.id)
            }
        }
        // Creator DLC are loaded by folder name, not workshop id. Matching on the display
        // name failed for every one of them: the server advertises "S.O.G. Prairie Fire"
        // while the folder on disk is `vn`.
        for dlc in server.dlcs where dlc.isCreatorDLC {
            if let mod = installedCreatorDLC(dlc) { ids.append(mod.id) }
        }
        library.replaceEnabled(with: ids, source: server.displayName)
        persistModSelection()
    }

    /// The locally installed folder for a Creator DLC, if it is there.
    func installedCreatorDLC(_ dlc: ServerDLC) -> Mod? {
        guard let folder = ArmaServerBrowserProtocol.creatorDLCFolders[dlc.appID] else {
            // Unknown CDLC: fall back to a name match rather than giving up.
            return library.mods.first {
                $0.origin == .bundled && $0.name.localizedCaseInsensitiveContains(dlc.name)
            }
        }
        return library.mods.first {
            $0.origin == .bundled
                && $0.folderName.compare(folder, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Creator DLC a server needs that are not installed. These cannot be downloaded from
    /// the Workshop — they are paid content — so they need saying out loud.
    func missingCreatorDLC(for server: GameServer) -> [ServerDLC] {
        server.dlcs.filter { $0.isCreatorDLC && installedCreatorDLC($0) == nil }
    }

    func join(server: GameServer, password: String?) {
        browser.noteJoined(server)
        persistBrowserState()
        let target = ConnectTarget(address: server.address, password: password)
        // A server dictates its own mod set, so joining always runs the modded path —
        // even if the launcher is parked on Vanilla for solo play.
        launch(mode: server.mods.isEmpty ? settings.launchMode : .modded, connect: target)
        pendingJoin = nil
    }

    // MARK: - Is the game already up?

    /// True when Arma appears to be running already.
    ///
    /// Cached rather than computed: `runningApplications` enumerates every process, and a
    /// computed property would run that on every render of the launch bar. It is refreshed
    /// from the workspace's launch/quit notifications instead, which also keeps it live.
    private(set) var isGameRunning = false

    private func refreshGameRunning() {
        if let runningProcess, runningProcess.isRunning {
            isGameRunning = true
            return
        }
        isGameRunning = runningGameApplication() != nil
    }

    private func runningGameApplication() -> NSRunningApplication? {
        guard let installation = selectedInstallation else { return nil }
        let bundles = Set(
            installation.executables
                .filter { $0.url.pathExtension == "app" }
                .map(\.url.standardizedFileURL)
        )
        guard !bundles.isEmpty else { return nil }

        return NSWorkspace.shared.runningApplications.first { application in
            guard let url = application.bundleURL?.standardizedFileURL else { return false }
            return bundles.contains(url)
        }
    }

    /// Watches for the game starting or quitting, so the Play button reflects reality
    /// without polling.
    private func observeGameLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshGameRunning() }
            }
        }
    }

    /// Brings the running game forward instead of starting another copy.
    func focusRunningGame() {
        runningGameApplication()?.activate(options: [.activateAllWindows])
    }

    // MARK: - Player profile

    /// The Arma profile the game will start with. Without an explicit `-name=`, Arma uses
    /// its default profile.
    var activeProfile: ArmaProfile? {
        let configured = settings.launchOptions.profileName
        if let configured, !configured.isEmpty {
            return gameSettings.profiles.first { $0.name == configured }
        }
        return gameSettings.profiles.first(where: \.isDefault) ?? gameSettings.profiles.first
    }

    /// Name shown in the UI, even when the profile file has not been found yet.
    var activeProfileName: String {
        if let activeProfile { return activeProfile.name }
        let configured = settings.launchOptions.profileName
        if let configured, !configured.isEmpty { return configured }
        return "Default"
    }

    func useProfile(_ profile: ArmaProfile) {
        // The default profile is the one Arma picks with no argument at all.
        settings.launchOptions.profileName = profile.isDefault ? nil : profile.name
        gameSettings.selectedProfile = profile
    }

    func refreshProfiles() {
        gameSettings.refresh(installation: selectedInstallation)
    }

    /// The server the player most recently joined, if it is still in the browser's list.
    var lastPlayedServer: GameServer? {
        guard let key = browser.recents.first,
              let address = ServerBrowserModel.parseAddress(key)
        else { return nil }
        return browser.serversByAddress[address]
    }

    /// Starts downloading the mods a server needs.
    ///
    /// `joinWhenReady` carries the join through to the other side of the download, so an
    /// automatic install ends in the game starting rather than in another prompt.
    func downloadMissingMods(for join: PendingJoin, joinWhenReady: Bool = false) {
        let ids = join.missing.map(\.publishedFileID)
        let names = Dictionary(
            join.missing.map { ($0.publishedFileID, $0.name.isEmpty ? "Workshop item \($0.publishedFileID)" : $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        joinAfterDownload = joinWhenReady ? join.server.address : nil
        downloader.start(ids: ids, names: names)
    }

    /// Server to join once the running download finishes, if the user asked for a join.
    private var joinAfterDownload: ServerAddress?

    /// Downloads any workshop item, from the mod manager or a pasted collection link.
    func download(ids: [UInt64], names: [UInt64: String] = [:]) {
        guard !ids.isEmpty else { return }
        joinAfterDownload = nil
        downloader.start(ids: ids, names: names)
    }

    /// Runs after every download, once the library has been rescanned.
    ///
    /// A join that was waiting on mods only goes ahead when every one of them actually
    /// arrived; anything less leaves the sheet up with the failures visible.
    private func downloadsFinished() {
        guard let address = joinAfterDownload else { return }
        joinAfterDownload = nil
        guard let pending = pendingJoin, pending.server.address == address else { return }

        let installed = Set(library.mods.compactMap(\.publishedFileID))
        let stillMissing = pending.missing.filter { !installed.contains($0.publishedFileID) }
        guard stillMissing.isEmpty else {
            statusMessage = nil
            return
        }
        guard !pending.server.isPasswordProtected else {
            statusMessage = "Mods installed — enter the server password to join."
            return
        }
        applyServerModSelection(pending.server)
        join(server: pending.server, password: nil)
    }

    /// Puts back the load order from before the last server join or preset.
    func restorePreviousLoadOrder() {
        guard library.canRestorePreviousOrder else { return }
        library.restorePreviousOrder()
        persistModSelection()
        statusMessage = "Load order restored."
    }

    /// Re-downloads every mod with a newer version on the Workshop.
    func updateOutdatedMods() {
        let outdated = library.outdatedMods
        guard !outdated.isEmpty else {
            statusMessage = "All Workshop mods are up to date."
            return
        }
        let ids = outdated.compactMap(\.publishedFileID)
        let names = Dictionary(
            outdated.compactMap { mod in mod.publishedFileID.map { ($0, mod.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        download(ids: ids, names: names)
    }

    /// Resolves a Workshop collection URL or id into its items and queues them.
    func importCollection(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let id = PresetHTML.workshopID(fromURL: trimmed) ?? UInt64(trimmed)
        guard let id else {
            alert = AlertPayload(
                title: "Not a collection link",
                message: "Paste a Steam Workshop collection URL or its numeric id."
            )
            return
        }
        do {
            let api = SteamWorkshopAPI()
            let items = try await api.collectionItems(collectionID: id)
            guard !items.isEmpty else {
                alert = AlertPayload(
                    title: "Empty collection",
                    message: "Steam returned no items for collection \(id).",
                    isError: false
                )
                return
            }
            let details = (try? await api.details(for: items)) ?? [:]
            let names = details.mapValues(\.title)
            let installed = Set(library.mods.compactMap(\.publishedFileID))
            let missing = items.filter { !installed.contains($0) }

            // Apply the order straight away, keeping the raw workshop id for anything not
            // installed yet — the same trick presets use, so the entries resolve by
            // themselves once the downloads land. Previously a collection with missing mods
            // downloaded them and set no order at all.
            library.replaceEnabled(
                with: items.map { id in
                    library.mod(publishedFileID: id)?.id ?? String(id)
                },
                source: "collection"
            )
            persistModSelection()
            settings.launchMode = .modded

            if missing.isEmpty {
                statusMessage = "Collection applied — all \(items.count) mods were already installed."
            } else {
                statusMessage = "Collection applied. Installing \(missing.count) missing mod(s)…"
                download(ids: missing, names: names)
            }
        } catch {
            alert = AlertPayload(title: "Could not read collection", message: error.localizedDescription)
        }
    }

    // MARK: - Presets

    func savePreset(named name: String) {
        var preset = library.makePreset(named: name)
        if let index = settings.presets.firstIndex(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            preset.id = settings.presets[index].id
            preset.createdAt = settings.presets[index].createdAt
            preset.updatedAt = .now
            settings.presets[index] = preset
        } else {
            settings.presets.append(preset)
        }
    }

    func deletePreset(_ preset: Preset) {
        settings.presets.removeAll { $0.id == preset.id }
    }

    func applyPreset(_ preset: Preset) {
        library.applyPreset(preset)
        persistModSelection()
    }

    func exportPreset(named name: String) -> String {
        PresetHTML.export(name: name, mods: library.enabledMods)
    }

    /// Imports an Arma 3 Launcher HTML preset, offering to download whatever is missing.
    func importPreset(html: String, fallbackName: String) {
        let imported = PresetHTML.parse(html: html, fallbackName: fallbackName)
        let missing = library.apply(imported: imported)
        persistModSelection()
        savePreset(named: imported.name)

        guard !missing.isEmpty else {
            statusMessage = "Imported “\(imported.name)” — all \(imported.mods.count) mods present."
            return
        }
        let ids = missing.compactMap(\.publishedFileID)
        let names = Dictionary(
            missing.compactMap { mod in mod.publishedFileID.map { ($0, mod.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        if ids.isEmpty {
            alert = AlertPayload(
                title: "Some mods are missing",
                message: missing.map(\.name).joined(separator: "\n"),
                isError: false
            )
        } else {
            download(ids: ids, names: names)
        }
    }

    // MARK: - Utilities

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInSteam(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
