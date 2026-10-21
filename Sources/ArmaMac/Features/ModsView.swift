import SwiftUI
import UniformTypeIdentifiers

/// The mod manager, arranged the way the Arma 3 Launcher arranges it: an action row across
/// the top, then one list holding "Loaded mods" (the ordered set that will launch) above
/// "Available mods" (everything else installed), then a status line.
struct ModsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.windowWidth) private var windowWidth

    @State private var selection: Set<Mod.ID> = []
    @State private var searchText = ""
    @State private var originFilter: ModOrigin?
    @State private var showInspector = false
    @State private var wantsInspector = false
    @State private var showCollectionSheet = false
    @State private var collectionText = ""

    private var library: ModLibraryModel { app.library }

    /// The sidebar, the list's minimum width and the inspector together need roughly this
    /// much. Below it the inspector would hang off the window's edge.
    private var hasRoomForInspector: Bool { windowWidth >= 900 }

    /// Derived, never set directly — see the same note in `ServersView`.
    private func syncInspector() {
        let shouldShow = wantsInspector && hasRoomForInspector
        if showInspector != shouldShow { showInspector = shouldShow }
    }

    private var filteredMods: [Mod] {
        library.mods.filter { mod in
            if let originFilter, mod.origin != originFilter { return false }
            if !searchText.isEmpty {
                let matchesName = mod.name.localizedCaseInsensitiveContains(searchText)
                let matchesID = mod.publishedFileID.map { String($0).contains(searchText) } ?? false
                let matchesAuthor = mod.author?.localizedCaseInsensitiveContains(searchText) ?? false
                guard matchesName || matchesID || matchesAuthor else { return false }
            }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Anything installed that is not already in the load order. Ticking one moves it up
    /// into "Loaded mods", which is what the two sections are for.
    private var availableMods: [Mod] {
        filteredMods.filter { !library.isEnabled($0) }
    }

    private var selectedMod: Mod? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return library.mod(withID: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            modList
            Divider()
            statusLine
        }
        // See the note in ServersView: the rows' intrinsic width becomes the list's
        // minimum unless one is given, which overflows the window.
        .frame(minWidth: 340)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search mods")
        .toolbar { toolbarContent }
        .inspector(isPresented: $showInspector) {
            ModInspector(mod: selectedMod)
                .inspectorColumnWidth(min: 220, ideal: 290, max: 400)
        }
        .sheet(isPresented: $showCollectionSheet) { collectionSheet }
        .onChange(of: windowWidth, initial: true) { _, _ in syncInspector() }
        .onChange(of: wantsInspector) { _, _ in syncInspector() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await app.rescanMods() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Rescan mod folders (\u{21E7}\u{2318}R)")
        }

        ToolbarItem {
            Menu {
                Button("Workshop Collection…") { showCollectionSheet = true }
                Button("Local Folder…") { addLocalMod() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add mods to the library")
        }

        ToolbarItem {
            Menu {
                Button("Refresh Workshop Info") { library.refreshWorkshopDetails(force: true) }
                Button("Update \(library.outdatedMods.count) Outdated") {
                    app.updateOutdatedMods()
                }
                .disabled(library.outdatedMods.isEmpty)

                Divider()

                Picker("Source", selection: $originFilter) {
                    Text("All Sources").tag(ModOrigin?.none)
                    ForEach(ModOrigin.allCases, id: \.self) { origin in
                        Text(origin.displayName).tag(ModOrigin?.some(origin))
                    }
                }

                Divider()

                Button(restoreTitle) { app.restorePreviousLoadOrder() }
                    .disabled(!library.canRestorePreviousOrder)
                Button("Sort Load Order A–Z") { sortAlphabetically() }
                    .disabled(library.enabledIDs.isEmpty)
                Button("Remove Not Installed") {
                    library.enabledIDs.removeAll { library.mod(withID: $0) == nil }
                }
                .disabled(library.missingEnabledIDs.isEmpty)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem { ModsPresetMenu() }

        ToolbarItem { DownloadsChip() }

        ToolbarItem {
            Button {
                wantsInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .disabled(!hasRoomForInspector)
            .help(
                hasRoomForInspector
                    ? "Show the selected mod's details"
                    : "Widen the window to show details"
            )
        }
    }

    // MARK: - The two stacked sections

    private var modList: some View {
        @Bindable var library = app.library

        return List(selection: $selection) {
            Section {
                if library.enabledIDs.isEmpty {
                    Text("Tick mods below to load them in the game.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    ForEach(Array(library.enabledIDs.enumerated()), id: \.element) { index, id in
                        loadedRow(index: index, id: id)
                    }
                    .onMove { source, destination in
                        library.moveEnabled(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        library.enabledIDs.remove(atOffsets: offsets)
                    }
                }
            } header: {
                sectionHeader(
                    "Loaded mods",
                    count: library.enabledIDs.isEmpty ? nil : library.enabledIDs.count,
                    actionTitle: "Unload all",
                    enabled: !library.enabledIDs.isEmpty
                ) {
                    library.enabledIDs.removeAll()
                }
            }

            Section {
                ForEach(availableMods) { mod in
                    availableRow(mod).tag(mod.id)
                }
            } header: {
                sectionHeader(
                    "Available mods",
                    count: availableMods.count,
                    actionTitle: "Load all",
                    enabled: !availableMods.isEmpty
                ) {
                    for mod in availableMods { library.setEnabled(true, for: mod) }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: Mod.ID.self) { ids in
            contextMenu(for: ids)
        }
        .overlay {
            if library.mods.isEmpty && !library.isScanning {
                EmptyStateView(
                    title: "No mods found",
                    message: """
                    ArmaMac scans the Workshop folder of the selected install, any @folders \
                    in the game directory, and folders you add here or in Options.
                    """,
                    systemImage: "shippingbox",
                    actionTitle: "Rescan",
                    action: { Task { await app.rescanMods() } }
                )
                .background(.background)
            }
        }
    }

    private func sectionHeader(
        _ title: String,
        count: Int?,
        actionTitle: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .padding(.vertical, 2)
        .textCase(nil)
    }

    /// A row in the load order: position, the tick that removes it, and the mod.
    @ViewBuilder
    private func loadedRow(index: Int, id: String) -> some View {
        let mod = library.mod(withID: id)

        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.quaternary)

            Toggle("", isOn: Binding(
                get: { true },
                set: { _ in library.enabledIDs.removeAll { $0 == id } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)

            if let mod {
                Text(mod.name).lineLimit(1)
                Spacer(minLength: 8)
                ModOriginBadge(origin: mod.origin)
                Text(Format.bytes(mod.sizeOnDisk))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .trailing)
            } else {
                Text("Not installed").foregroundStyle(.orange).lineLimit(1)
                Text(id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let workshopID = UInt64(id) {
                    Button("Get") { app.download(ids: [workshopID]) }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.callout)
        .padding(.vertical, 1)
    }

    /// A row in the library: ticking it appends to the load order.
    private func availableRow(_ mod: Mod) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.clear)

            Toggle("", isOn: Binding(
                get: { library.isEnabled(mod) },
                set: { library.setEnabled($0, for: mod) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Spacer().frame(width: 20)

            Text(mod.name).lineLimit(1)

            if library.hasUpdate(mod) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .help("A newer version is on the Workshop")
            }
            if mod.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("This folder looks empty — the download may be incomplete")
            }

            Spacer(minLength: 8)

            ModOriginBadge(origin: mod.origin)
            Text(Format.bytes(mod.sizeOnDisk))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 1)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 10) {
            if library.isScanning {
                Text("Scanning mod folders…")
            } else if library.missingEnabledIDs.isEmpty {
                Text("\(library.mods.count) mods installed · \(library.enabledIDs.count) loaded")
            } else {
                Label("\(library.missingEnabledIDs.count) loaded mods are not installed",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if !library.outdatedMods.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text("\(library.outdatedMods.count) outdated").foregroundStyle(.blue)
            }

            Spacer(minLength: 8)

            if library.enabledSizeOnDisk > 0 {
                Text(Format.bytes(library.enabledSizeOnDisk))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<Mod.ID>) -> some View {
        let mods = ids.compactMap { library.mod(withID: $0) }

        Button("Load") { library.setEnabled(true, for: ids) }
        Button("Unload") { library.setEnabled(false, for: ids) }
        Divider()
        Button("Show in Finder") {
            guard let mod = mods.first else { return }
            app.revealInFinder(mod.path)
        }
        .disabled(mods.count != 1)
        Button("Open on Steam Workshop") {
            guard let url = mods.first?.steamProtocolURL else { return }
            app.openInSteam(url)
        }
        .disabled(mods.count != 1 || mods.first?.publishedFileID == nil)
        Divider()
        Button("Reinstall from the Workshop") {
            let ids = mods.compactMap(\.publishedFileID)
            let names = Dictionary(
                mods.compactMap { mod in mod.publishedFileID.map { ($0, mod.name) } },
                uniquingKeysWith: { first, _ in first }
            )
            app.download(ids: ids, names: names)
        }
        .disabled(mods.allSatisfy { $0.publishedFileID == nil })
    }

    // MARK: - Sheets and actions

    private var collectionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import a Workshop collection").font(.headline)
            Text("Paste a collection URL or id. Missing mods are queued for download; mods you already have are loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(
                "Collection",
                text: $collectionText,
                prompt: Text("https://steamcommunity.com/sharedfiles/filedetails/?id=…")
            )
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showCollectionSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let text = collectionText
                    showCollectionSheet = false
                    collectionText = ""
                    Task { await app.importCollection(text) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(collectionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// Names what the undo would put back, so it is obvious what changed the order.
    private var restoreTitle: String {
        guard let source = library.previousOrderSource else { return "Restore previous order" }
        return source == "restore"
            ? "Undo restore"
            : "Restore order from before \(source)"
    }

    private func sortAlphabetically() {
        library.enabledIDs.sort { lhs, rhs in
            let left = library.mod(withID: lhs)?.name ?? lhs
            let right = library.mod(withID: rhs)?.name ?? rhs
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    private func addLocalMod() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder holding mods"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path(percentEncoded: false)
            if !app.settings.extraModDirectories.contains(path) {
                app.settings.extraModDirectories.append(path)
            }
        }
        Task { await app.rescanMods() }
    }
}

/// The preset control the launcher puts opposite the section name, in the header band.
struct ModsPresetMenu: View {
    @Environment(AppModel.self) private var app

    @State private var showSaveSheet = false
    @State private var presetName = ""

    /// The launcher calls a load order that matches no saved preset an "unsaved preset".
    private var currentName: String {
        app.settings.presets
            .first { $0.modIDs == app.library.enabledIDs }?
            .name ?? "Unsaved preset"
    }

    var body: some View {
        HStack(spacing: 7) {
            Text("PRESET")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Menu(currentName) {
                Button("Save as…") {
                    presetName = ""
                    showSaveSheet = true
                }
                .disabled(app.library.enabledIDs.isEmpty)

                Button("Import preset (.html)…") { importPreset() }
                Button("Export preset (.html)…") { exportPreset() }
                    .disabled(app.library.enabledIDs.isEmpty)

                if !app.settings.presets.isEmpty {
                    Divider()
                    ForEach(app.settings.presets) { preset in
                        Button("\(preset.name) (\(preset.modIDs.count))") {
                            app.applyPreset(preset)
                            app.settings.launchMode = .modded
                        }
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(app.settings.presets) { preset in
                            Button(preset.name) { app.deletePreset(preset) }
                        }
                    }
                }
            }
            .fixedSize()
        }
        .sheet(isPresented: $showSaveSheet) { saveSheet }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save preset").font(.headline)
            Text("Stores the \(app.library.enabledIDs.count) loaded mods, in order, under a name you can re-apply later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.savePreset(named: presetName.trimmingCharacters(in: .whitespaces))
                    showSaveSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.message = "Choose an Arma 3 Launcher preset"
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        app.importPreset(html: html, fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    private func exportPreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "ArmaMac preset.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        try? app.exportPreset(named: name).write(to: url, atomically: true, encoding: .utf8)
    }
}
