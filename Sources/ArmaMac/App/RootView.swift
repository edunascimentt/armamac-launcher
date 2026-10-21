import SwiftUI

/// Width of the window's content area, published from the root.
///
/// Read from the `NSWindow` rather than a `GeometryReader`: once any content overflows, a
/// geometry proxy reports the overflowed size instead of the space actually available, so
/// it cannot be used to decide whether something fits.
private struct WindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1_060
}

extension EnvironmentValues {
    var windowWidth: CGFloat {
        get { self[WindowWidthKey.self] }
        set { self[WindowWidthKey.self] = newValue }
    }
}

/// Sidebar destinations.
enum AppTab: String, Hashable, CaseIterable, Identifiable {
    case home, profile, parameters, mods, servers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Dashboard"
        case .profile: "Profile"
        case .parameters: "Parameters"
        case .mods: "Mods"
        case .servers: "Servers"
        }
    }

    var symbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .profile: "person.crop.circle"
        case .parameters: "slider.horizontal.3"
        case .mods: "shippingbox"
        case .servers: "server.rack"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var tab: AppTab = .home
    @State private var didRestoreTab = false
    @State private var windowWidth: CGFloat = 1_060
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showNewProfile = false
    @State private var newProfileName = ""

    var body: some View {
        @Bindable var app = app

        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .navigationTitle(tab.title)
                .navigationSubtitle(subtitle)
                .toolbar { playItem }
        }
        .environment(\.windowWidth, windowWidth)
        .onAppear(perform: readWindowWidth)
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
        ) { notification in
            guard let window = notification.object as? NSWindow, window.isVisible else { return }
            windowWidth = window.contentLayoutRect.width
        }
        .alert(item: $app.alert) { payload in
            Alert(
                title: Text(payload.title),
                message: Text(payload.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(item: $app.pendingJoin) { join in
            JoinServerSheet(join: join)
                .environment(app)
        }
        .sheet(isPresented: $showNewProfile) { newProfileSheet }
        .onChange(of: app.library.enabledIDs) { _, _ in app.persistModSelection() }
        .onChange(of: app.browser.favourites) { _, _ in app.persistBrowserState() }
        .onChange(of: app.browser.sortRules) { _, _ in app.persistBrowserState() }
        .onAppear {
            // Restore once. Persisting before this would save the placeholder value.
            guard !didRestoreTab else { return }
            tab = AppTab(rawValue: app.settings.lastSection) ?? .home
            didRestoreTab = true
        }
        .onChange(of: tab) { _, newValue in
            guard didRestoreTab else { return }
            app.settings.lastSection = newValue.rawValue
        }
    }

    /// The window subtitle carries what will launch, so no view has to spend space on it.
    private var subtitle: String {
        guard let installation = app.selectedInstallation else { return "No Arma 3 install found" }
        let mods = app.settings.launchMode == .vanilla
            ? "Vanilla"
            : "\(app.library.enabledMods.count) mods"
        return "\(installation.library.displayName) · \(app.activeProfileName) · \(mods)"
    }

    private func readWindowWidth() {
        // The first layout pass can run before the window exists.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else { return }
            windowWidth = window.contentLayoutRect.width
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // A non-optional selection: SwiftUI clears an optional one during the split view's
        // first layout, which would wipe the restored tab.
        let selection = Binding<AppTab?>(
            get: { tab },
            set: { if let newValue = $0 { tab = newValue } }
        )

        return List(selection: selection) {
            Section {
                ForEach(AppTab.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(badge(for: item))
                        .tag(item)
                }
            }

            Section("Presets") {
                if app.settings.presets.isEmpty {
                    Text("No presets yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(app.settings.presets) { preset in
                        Button {
                            app.applyPreset(preset)
                            app.settings.launchMode = .modded
                        } label: {
                            Label {
                                Text(preset.name)
                                Text("\(preset.modIDs.count) mods")
                            } icon: {
                                Image(systemName: "bookmark")
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Apply") { app.applyPreset(preset) }
                            Button("Delete", role: .destructive) { app.deletePreset(preset) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 270)
    }

    private func badge(for item: AppTab) -> Int {
        switch item {
        case .mods: app.library.enabledIDs.count
        case .home, .profile, .parameters, .servers: 0
        }
    }

    // MARK: - Play

    /// The window's primary action, at the trailing end of the toolbar where the system
    /// gives it the prominent treatment.
    @ToolbarContentBuilder
    private var playItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            let running = app.isGameRunning

            Menu {
                playMenuItems
            } label: {
                Label(
                    running ? "Bring to Front" : "Play",
                    systemImage: running ? "arrow.up.forward.app.fill" : "play.fill"
                )
            } primaryAction: {
                // Starting a second copy helps nobody; surface the one already up.
                if running { app.focusRunningGame() } else { app.launch() }
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .disabled(!app.canLaunch)
            .help(running ? "Bring the running game forward (⌘↩)" : "Launch Arma 3 (⌘↩)")
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    @ViewBuilder
    private var playMenuItems: some View {
        @Bindable var app = app

        Group {
            Picker("Mods", selection: $app.settings.launchMode) {
                ForEach(LaunchMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }

            if let server = app.lastPlayedServer {
                Button {
                    Task { await app.prepareJoin(server: server) }
                } label: {
                    Label("Rejoin \(server.displayName)", systemImage: "arrow.uturn.right")
                }
            }

            Divider()

            Menu("Installation") {
                ForEach(app.installations) { installation in
                    Button {
                        app.selectedInstallation = installation
                        Task { await app.rescanMods() }
                    } label: {
                        if installation == app.selectedInstallation {
                            Label(installation.library.displayName, systemImage: "checkmark")
                        } else {
                            Text(installation.library.displayName)
                        }
                    }
                }
                if !app.installations.isEmpty { Divider() }
                Button("Search Again…") {
                    Task { await app.detectInstallations(); await app.rescanMods() }
                }
            }

            Menu("Profile") {
                ForEach(app.gameSettings.profiles) { profile in
                    Button {
                        app.useProfile(profile)
                    } label: {
                        if profile.name == app.activeProfileName {
                            Label(profile.displayName, systemImage: "checkmark")
                        } else {
                            Text(profile.displayName)
                        }
                    }
                }
                Divider()
                Button("New Profile…") {
                    newProfileName = ""
                    showNewProfile = true
                }
                Button("Rescan Profiles") { app.refreshProfiles() }
            }

            Divider()

            Toggle("Launch Through Steam", isOn: $app.settings.launchThroughSteam)
            Toggle("BattlEye", isOn: $app.settings.launchOptions.useBattlEye)
            Toggle("Windowed", isOn: $app.settings.launchOptions.windowed)

            Divider()

            Button("Copy Command Line") {
                guard let plan = app.previewPlan() else { return }
                app.copyToPasteboard(plan.displayCommand)
            }
        }
    }

    private var newProfileSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New player profile").font(.headline)
            Text("Arma keeps its own settings, keybinds and difficulty per profile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { if canCreateProfile { createProfile() } }

            if !newProfileName.trimmingCharacters(in: .whitespaces).isEmpty, !canCreateProfile {
                Label("That name is already taken.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { showNewProfile = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createProfile() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreateProfile)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var canCreateProfile: Bool {
        app.gameSettings.isNameAvailable(newProfileName)
    }

    private func createProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        app.gameSettings.createProfile(
            named: name, copying: nil, installation: app.selectedInstallation
        )
        // Switch to it right away — creating one from here means you want to use it.
        if let created = app.gameSettings.profiles.first(where: { $0.name == name }) {
            app.useProfile(created)
        }
        showNewProfile = false
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .home: HomeView { tab = $0 }
        case .profile: ProfileView()
        case .parameters: ParametersView()
        case .mods: ModsView()
        case .servers: ServersView()
        }
    }
}

/// Menu-bar commands so the keyboard works the way Mac users expect.
struct LauncherCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Play") { app.launch() }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(!app.canLaunch)

            Button("Play Vanilla") { app.launch(mode: .vanilla) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!app.canLaunch)

            Button("Play with Mods") { app.launch(mode: .modded) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!app.canLaunch || app.library.enabledMods.isEmpty)

            Divider()

            Button("Refresh Server List") { app.browser.refresh(settings: app.settings) }
                .keyboardShortcut("r", modifiers: [.command])

            Button("Rescan Mods") { Task { await app.rescanMods() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Import Preset…") { importPreset() }
                .keyboardShortcut("i", modifiers: [.command])
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Arma 3 Launcher preset (.html)"
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        app.importPreset(
            html: html,
            fallbackName: url.deletingPathExtension().lastPathComponent
        )
    }
}
