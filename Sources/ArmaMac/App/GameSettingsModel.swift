import Foundation
import Observation

/// Reads and writes Arma's own settings files, so the launcher can configure the game
/// without opening it.
@MainActor
@Observable
final class GameSettingsModel {
    private(set) var profiles: [ArmaProfile] = []
    var selectedProfile: ArmaProfile? {
        didSet {
            if selectedProfile != oldValue { load() }
        }
    }

    // Field of view
    var horizontalFOV: Double = FieldOfView.arma3Default.horizontalDegrees
    var aspectRatio: Double = 16.0 / 9.0

    // Video settings from Arma3.cfg
    var viewDistance: Double = 1_600
    var objectViewDistance: Double = 1_200
    var terrainQuality: TerrainQuality = .standard
    var hasVideoConfig = false

    private(set) var loadedFOV: FieldOfView = .arma3Default
    private(set) var isDirty = false
    var status: String?
    var errorMessage: String?

    private let locator = ArmaProfileLocator()

    /// Arma's `terrainGrid` is a mesh size in metres: smaller is more detailed.
    enum TerrainQuality: Double, CaseIterable, Identifiable, Sendable {
        case ultra = 3.125
        case high = 6.25
        case standard = 12.5
        case low = 25
        case veryLow = 50

        var id: Double { rawValue }

        var title: String {
            switch self {
            case .ultra: "Ultra"
            case .high: "High"
            case .standard: "Standard"
            case .low: "Low"
            case .veryLow: "Very low"
            }
        }

        static func closest(to value: Double) -> TerrainQuality {
            allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .standard
        }
    }

    var currentFOV: FieldOfView {
        FieldOfView(horizontalDegrees: horizontalFOV, aspectRatio: aspectRatio)
    }

    var isDefaultFOV: Bool {
        abs(horizontalFOV - FieldOfView.arma3Default.horizontalDegrees) < 0.05
            && abs(aspectRatio - FieldOfView.arma3Default.aspectRatio) < 0.01
    }

    // MARK: - Loading

    func refresh(installation: GameInstallation?) {
        profiles = locator.profiles(for: installation)

        // Match on the file, not the whole struct: when Arma writes Arma3.cfg for the first
        // time the profile's `configURL` changes, and struct equality would treat that as a
        // different profile and silently jump the selection to another one.
        if let current = selectedProfile,
           let refreshed = profiles.first(where: { $0.profileURL == current.profileURL }) {
            if refreshed != current { selectedProfile = refreshed }
            return
        }

        selectedProfile = profiles.first
        if selectedProfile == nil { load() }
    }

    // MARK: - Profile management

    /// Creates the default profile, for setups where Arma has never run.
    func createDefaultProfile(installation: GameInstallation?) {
        run(installation: installation, success: { "Created \($0.name)." }) {
            try locator.createDefaultProfile()
        }
    }

    /// Creates a named profile, optionally copying an existing one's settings.
    func createProfile(
        named name: String,
        copying source: ArmaProfile?,
        installation: GameInstallation?
    ) {
        run(installation: installation, success: { "Created “\($0.name)”." }) {
            try locator.createProfile(named: name, copying: source)
        }
    }

    func duplicateProfile(
        _ profile: ArmaProfile, named name: String, installation: GameInstallation?
    ) {
        run(installation: installation, success: { "Duplicated to “\($0.name)”." }) {
            try locator.createProfile(named: name, copying: profile)
        }
    }

    func renameProfile(
        _ profile: ArmaProfile, to name: String, installation: GameInstallation?
    ) {
        run(installation: installation, success: { "Renamed to “\($0.name)”." }) {
            try locator.renameProfile(profile, to: name)
        }
    }

    func deleteProfile(_ profile: ArmaProfile, installation: GameInstallation?) {
        do {
            try locator.deleteProfile(profile)
            selectedProfile = nil
            refresh(installation: installation)
            status = "Moved “\(profile.name)” to the Trash."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True when a name is free to use.
    func isNameAvailable(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !profiles.contains { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    /// Runs a profile operation, then reselects the result and reloads its settings.
    private func run(
        installation: GameInstallation?,
        success: (ArmaProfile) -> String,
        operation: () throws -> ArmaProfile
    ) {
        do {
            let profile = try operation()
            refresh(installation: installation)
            selectedProfile = profiles.first { $0.profileURL == profile.profileURL } ?? profile
            status = success(profile)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load() {
        isDirty = false
        status = nil
        errorMessage = nil

        guard let profile = selectedProfile,
              let editor = try? ArmaConfigEditor(contentsOf: profile.profileURL)
        else {
            loadedFOV = .arma3Default
            horizontalFOV = loadedFOV.horizontalDegrees
            aspectRatio = loadedFOV.aspectRatio
            hasVideoConfig = false
            return
        }

        let top = editor.doubleValue(for: "fovTop") ?? FieldOfView.arma3Default.fovTop
        let left = editor.doubleValue(for: "fovLeft") ?? FieldOfView.arma3Default.fovLeft
        loadedFOV = FieldOfView(fovTop: top, fovLeft: left)
        horizontalFOV = loadedFOV.horizontalDegrees
        aspectRatio = loadedFOV.aspectRatio

        loadVideoSettings(profile: profile)
    }

    private func loadVideoSettings(profile: ArmaProfile) {
        guard let configURL = profile.configURL,
              let config = try? ArmaConfigEditor(contentsOf: configURL)
        else {
            hasVideoConfig = false
            return
        }
        hasVideoConfig = true
        viewDistance = config.doubleValue(for: "viewDistance") ?? 1_600
        objectViewDistance = config.doubleValue(for: "preferredObjectViewDistance") ?? 1_200
        terrainQuality = .closest(to: config.doubleValue(for: "terrainGrid") ?? 12.5)

        // A resolution in the config is the best guess at the display's shape.
        if let width = config.doubleValue(for: "Resolution_W"),
           let height = config.doubleValue(for: "Resolution_H"),
           width > 0, height > 0 {
            let ratio = width / height
            if abs(ratio - aspectRatio) > 0.02, loadedFOV == .arma3Default {
                aspectRatio = ratio
            }
        }
    }

    func markDirty() { isDirty = true }

    // MARK: - Saving

    /// Writes the FOV pair and, when present, the video settings.
    func apply() {
        guard let profile = selectedProfile else {
            errorMessage = "No Arma profile selected."
            return
        }

        do {
            var editor = try ArmaConfigEditor(contentsOf: profile.profileURL)
            let fov = currentFOV
            editor.setValue(fov.fovTopText, for: "fovTop")
            editor.setValue(fov.fovLeftText, for: "fovLeft")
            try editor.write(to: profile.profileURL)
            loadedFOV = fov

            if let configURL = profile.configURL {
                var config = try ArmaConfigEditor(contentsOf: configURL)
                config.setValue(Int(viewDistance.rounded()), for: "viewDistance")
                config.setValue(
                    Int(objectViewDistance.rounded()), for: "preferredObjectViewDistance"
                )
                config.setValue(terrainQuality.rawValue, for: "terrainGrid")
                try config.write(to: configURL)
            }

            isDirty = false
            errorMessage = nil
            status = "Saved to \(profile.name). A backup of the original is beside it."
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    func resetFOVToDefault() {
        let defaults = FieldOfView.arma3Default
        aspectRatio = defaults.aspectRatio
        horizontalFOV = defaults.horizontalDegrees
        isDirty = true
    }

    /// Reverts the on-screen values to whatever is currently on disk.
    func discardChanges() { load() }
}
