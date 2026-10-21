import Foundation
import Observation

/// The scanned mod library plus the user's enabled selection and load order.
@MainActor
@Observable
final class ModLibraryModel {
    private(set) var mods: [Mod] = []
    private(set) var details: [UInt64: WorkshopDetails] = [:]
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    var scanError: String?

    /// Enabled mod ids, in load order. Mods not present locally are kept so that a preset
    /// survives a mod being uninstalled and reinstalled.
    var enabledIDs: [String] = []

    /// The order in place before the last wholesale replacement, so joining a server or
    /// applying a preset can be undone without rebuilding the list by hand.
    private(set) var previousEnabledIDs: [String]?

    /// What replaced the order, for labelling the undo action.
    private(set) var previousOrderSource: String?

    var canRestorePreviousOrder: Bool { previousEnabledIDs != nil }

    /// Replaces the whole load order, remembering what was there before.
    func replaceEnabled(with ids: [String], source: String) {
        let incoming = ids.uniqued()
        guard incoming != enabledIDs else { return }
        previousEnabledIDs = enabledIDs
        previousOrderSource = source
        enabledIDs = incoming
    }

    /// Puts back the order from before the last replacement.
    @discardableResult
    func restorePreviousOrder() -> Bool {
        guard let previous = previousEnabledIDs else { return false }
        // Swap, so restoring is itself undoable.
        previousEnabledIDs = enabledIDs
        previousOrderSource = "restore"
        enabledIDs = previous
        return true
    }

    private let api = SteamWorkshopAPI()
    private var detailsTask: Task<Void, Never>?

    var enabledMods: [Mod] {
        let index = Dictionary(mods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return enabledIDs.compactMap { index[$0] }
    }

    /// Disk footprint of the enabled mods, when sizes are known.
    var enabledSizeOnDisk: Int64 {
        enabledMods.reduce(0) { $0 + ($1.sizeOnDisk ?? 0) }
    }

    var missingEnabledIDs: [String] {
        let available = Set(mods.map(\.id))
        return enabledIDs.filter { !available.contains($0) }
    }

    func isEnabled(_ mod: Mod) -> Bool { enabledIDs.contains(mod.id) }

    func setEnabled(_ enabled: Bool, for mod: Mod) {
        if enabled {
            guard !enabledIDs.contains(mod.id) else { return }
            enabledIDs.append(mod.id)
        } else {
            enabledIDs.removeAll { $0 == mod.id }
        }
    }

    func toggle(_ mod: Mod) { setEnabled(!isEnabled(mod), for: mod) }

    func setEnabled(_ enabled: Bool, for selection: Set<Mod.ID>) {
        for id in selection {
            guard let mod = mods.first(where: { $0.id == id }) else { continue }
            setEnabled(enabled, for: mod)
        }
    }

    func moveEnabled(fromOffsets source: IndexSet, toOffset destination: Int) {
        enabledIDs.move(fromOffsets: source, toOffset: destination)
    }

    func mod(withID id: String) -> Mod? { mods.first { $0.id == id } }

    func mod(publishedFileID: UInt64) -> Mod? {
        mods.first { $0.publishedFileID == publishedFileID }
    }

    // MARK: - Scanning

    /// Rescans every mod source. Sizes are computed off the main actor because a large
    /// workshop folder can take a second or two to walk.
    func scan(
        installation: GameInstallation?,
        extraDirectories: [URL],
        includeOfficial: Bool,
        computeSizes: Bool = true
    ) async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }

        var directories = extraDirectories
        // Mods an older build downloaded with SteamCMD live outside the game's own Steam
        // library; they still load, so they are still scanned.
        let legacyContent = AppPaths.legacySteamCMDContent
        if FileManager.default.fileExists(atPath: legacyContent.path(percentEncoded: false)) {
            directories.append(legacyContent)
        }

        let scanner = ModScanner(includeOfficial: includeOfficial, computeSizes: computeSizes)
        let snapshot = installation
        let found = await Task.detached(priority: .userInitiated) {
            scanner.scan(installation: snapshot, extraDirectories: directories)
        }.value

        mods = found
        lastScan = .now
        refreshWorkshopDetails()
    }

    /// Fetches titles, previews and update times for every workshop mod we know about.
    func refreshWorkshopDetails(force: Bool = false) {
        let ids = mods.compactMap(\.publishedFileID)
            .filter { force || details[$0] == nil }
        guard !ids.isEmpty else { return }

        detailsTask?.cancel()
        detailsTask = Task { [api] in
            guard let fetched = try? await api.details(for: ids) else { return }
            guard !Task.isCancelled else { return }
            details.merge(fetched) { _, new in new }
        }
    }

    func detail(for mod: Mod) -> WorkshopDetails? {
        mod.publishedFileID.flatMap { details[$0] }
    }

    /// Mods whose Workshop copy is newer than the one on disk.
    var outdatedMods: [Mod] { mods.filter { hasUpdate($0) } }

    /// True when Steam has a newer version than the copy on disk.
    func hasUpdate(_ mod: Mod) -> Bool {
        guard let detail = detail(for: mod), let remote = detail.timeUpdated,
              let ticks = mod.metaTimestamp
        else { return false }
        // meta.cpp timestamps are Windows FILETIME-style 100 ns ticks since 1601.
        let local = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
        return remote.timeIntervalSince(local) > 60
    }

    // MARK: - Presets

    func applyPreset(_ preset: Preset) {
        replaceEnabled(with: preset.modIDs, source: "preset “\(preset.name)”")
    }

    func makePreset(named name: String, sourceServer: String? = nil) -> Preset {
        Preset(name: name, modIDs: enabledIDs, sourceServer: sourceServer)
    }

    /// Turns an imported HTML preset into an enabled selection, reporting what is missing.
    @discardableResult
    func apply(imported: PresetHTML.ImportedPreset) -> [PresetHTML.ImportedMod] {
        var resolved: [String] = []
        var missing: [PresetHTML.ImportedMod] = []

        for entry in imported.mods {
            if let id = entry.publishedFileID, let mod = mod(publishedFileID: id) {
                resolved.append(mod.id)
            } else if let match = mods.first(where: {
                $0.name.compare(entry.name, options: .caseInsensitive) == .orderedSame
            }) {
                resolved.append(match.id)
            } else {
                missing.append(entry)
                // Keep the id so the entry reappears once the mod is downloaded.
                if let id = entry.publishedFileID { resolved.append(String(id)) }
            }
        }
        replaceEnabled(with: resolved, source: "preset “\(imported.name)”")
        return missing
    }
}
