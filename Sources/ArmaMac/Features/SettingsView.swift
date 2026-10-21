import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            SteamSettingsTab()
                .tabItem { Label("Steam", systemImage: "person.crop.circle") }
            NetworkSettingsTab()
                .tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 580, height: 480)
    }
}

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        Form {
            Section("Installation") {
                if app.installations.isEmpty {
                    Text("No Arma 3 install detected.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Arma 3", selection: Binding(
                        get: { app.selectedInstallation },
                        set: { app.selectedInstallation = $0; Task { await app.rescanMods() } }
                    )) {
                        ForEach(app.installations) { installation in
                            Text(installation.displayName).tag(Optional(installation))
                        }
                    }
                }
                Button("Search for installs again") {
                    Task { await app.detectInstallations(); await app.rescanMods() }
                }

                if let installation = app.selectedInstallation {
                    LabeledContent("Path") {
                        Text(installation.directory.path(percentEncoded: false))
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                    LabeledContent("Runtime") {
                        Text(runtimeDescription(installation.container))
                    }
                    LabeledContent("Binaries") {
                        Text(installation.executables.map(\.kind.displayName).joined(separator: ", "))
                    }
                }
            }

            Section("Mods") {
                Toggle("Show official DLC as mods", isOn: $app.settings.showOfficialMods)
                    .onChange(of: app.settings.showOfficialMods) { _, _ in
                        Task { await app.rescanMods() }
                    }
                Toggle("Link Workshop mods into !Workshop before launch",
                       isOn: $app.settings.linkWorkshopMods)
                    .help("""
                    Creates symlinks inside the Arma folder so mod paths stay short and \
                    stay on the same drive letter under Wine.
                    """)

                LabeledContent("Extra mod folders") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.settings.extraModDirectories, id: \.self) { path in
                            HStack {
                                Text(path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer()
                                Button {
                                    app.settings.extraModDirectories.removeAll { $0 == path }
                                    Task { await app.rescanMods() }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add folder…") { addFolder() }
                            .controlSize(.small)
                    }
                }
            }

            Section("Server browser") {
                Toggle("Refresh the server list on launch", isOn: $app.settings.autoRefreshOnOpen)
            }
        }
        .formStyle(.grouped)
    }

    private func runtimeDescription(_ container: RuntimeContainer) -> String {
        switch container {
        case .native: "Native macOS build"
        case let .crossover(bottle, _): "CrossOver bottle “\(bottle)”"
        case let .wine(name, _, binary):
            "Wine (\(name)) — \(binary.lastPathComponent)"
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder containing mods"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        guard !app.settings.extraModDirectories.contains(path) else { return }
        app.settings.extraModDirectories.append(path)
        Task { await app.rescanMods() }
    }
}

struct ParametersSettingsTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let options = $app.settings.launchOptions

        Form {
            Section("Startup") {
                Toggle("Skip intro", isOn: options.skipIntro)
                Toggle("No splash screen", isOn: options.noSplash)
                Toggle("Empty world (fastest start)", isOn: options.emptyWorld)
                Toggle("Windowed", isOn: options.windowed)
                Toggle("Do not pause when unfocused", isOn: options.noPause)
            }

            Section("Game") {
                Toggle("Enable BattlEye", isOn: options.useBattlEye)
                Toggle("Prefer 64-bit binary", isOn: options.prefer64Bit)
                Toggle("Check signatures", isOn: options.checkSignatures)
                Toggle("Allow file patching", isOn: options.filePatching)
                Toggle("Show script errors", isOn: options.showScriptErrors)
                Toggle("Disable logs", isOn: options.noLogs)
                Toggle("Launch through the Steam client", isOn: $app.settings.launchThroughSteam)
            }

            Section("Performance") {
                LabeledContent("Max memory (MB)") {
                    TextField("auto", value: options.maxMemoryMB, format: .number)
                        .frame(width: 90)
                }
                LabeledContent("CPU count") {
                    TextField("auto", value: options.cpuCount, format: .number)
                        .frame(width: 90)
                }
                LabeledContent("Extra threads") {
                    TextField("auto", value: options.extraThreads, format: .number)
                        .frame(width: 90)
                }
                Toggle("Enable hyperthreading", isOn: options.enableHyperThreading)
            }

            Section("Profile") {
                LabeledContent("Player profile") {
                    TextField("default", text: Binding(
                        get: { app.settings.launchOptions.profileName ?? "" },
                        set: { app.settings.launchOptions.profileName = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(width: 180)
                }
            }

            Section("Custom parameters") {
                TextField(
                    "",
                    text: options.customParameters,
                    prompt: Text("-nologs -world=empty"),
                    axis: .vertical
                )
                .lineLimit(2...4)
                .font(.callout.monospaced())
            }
        }
        .formStyle(.grouped)
    }
}

struct SteamSettingsTab: View {
    @Environment(AppModel.self) private var app
    /// Recomputed when the tab appears rather than polled; Steam rarely changes state
    /// while someone is looking at a settings pane.
    @State private var steamRunning = SteamClientApp.isRunning

    var body: some View {
        @Bindable var app = app

        Form {
            Section("Installing mods") {
                Toggle("Install a server's missing mods and join automatically",
                       isOn: $app.settings.autoInstallServerMods)
                Text("""
                Mods are installed through the Steam client you are already signed in to — \
                the same thing pressing Subscribe on a Workshop page does. Nothing to \
                install, no credentials, and the mods land in your normal Steam workshop \
                folder. Steam is started for you if it is not already up.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Steam client") {
                LabeledContent("Status") {
                    if steamRunning {
                        Label("Running", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not running", systemImage: "xmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("Steam API") {
                    if app.browser.steamDylib != nil {
                        Label("Found in Arma 3", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if app.browser.steamDylib == nil {
                    Text("""
                    libsteam_api.dylib ships inside Arma 3's app bundle and is what lets the \
                    launcher talk to Steam. Point ArmaMac at a native Arma 3 install in the \
                    Game tab to install mods from here.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Refresh") { steamRunning = SteamClientApp.isRunning }
                    if !steamRunning {
                        Button("Start Steam") {
                            Task {
                                await SteamClientApp.launch()
                                steamRunning = SteamClientApp.isRunning
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { steamRunning = SteamClientApp.isRunning }
    }
}

struct NetworkSettingsTab: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        Form {
            Section("Server queries") {
                Toggle("Read every server's mod list after refreshing",
                       isOn: $app.settings.autoLoadModLists)
                    .help("""
                    Fills the Mods column for the whole list. It is a second query pass over \
                    a few thousand servers, so it runs in the background after pinging and \
                    can be stopped from the toolbar.
                    """)

                LabeledContent("Timeout (ms)") {
                    TextField("", value: $app.settings.queryTimeoutMilliseconds, format: .number)
                        .frame(width: 90)
                }
                LabeledContent("Concurrent queries") {
                    TextField("", value: $app.settings.queryConcurrency, format: .number)
                        .frame(width: 90)
                }
                Text("""
                Higher concurrency fills the list faster but can trip home-router NAT limits. \
                96 is a safe default; drop to 32 if servers show as unreachable in bulk.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Server list source") {
                LabeledContent("Steam client") {
                    if app.browser.steamDylib != nil {
                        Label("Available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("libsteam_api.dylib not found", systemImage: "xmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                Text("""
                The community list comes from your running Steam client — the same list \
                Steam's own server browser shows. No API key, no third-party site. Steam \
                just needs to be running and signed in.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("Steam Web API key (optional fallback)") {
                Text("""
                Only used if the Steam client route is unavailable — for example when Arma \
                is installed in a Wine bottle with no macOS Steam library on this Mac. \
                Leave it empty otherwise.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                SecureField("API key", text: $app.settings.steamWebAPIKey)
            }
        }
        .formStyle(.grouped)
    }
}
