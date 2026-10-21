import AppKit
import Foundation

/// The Steam client application itself — as opposed to the Steam *library* on disk.
///
/// Installing mods goes through the running client, so the launcher needs to know whether
/// it is up and be able to start it without the user going hunting for it.
enum SteamClientApp {
    static let bundleIdentifier = "com.valvesoftware.steam"

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == bundleIdentifier }
    }

    /// The installed Steam.app, wherever it is.
    static func locate() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        let candidates = [
            URL(filePath: "/Applications/Steam.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/Steam.app"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// Starts Steam without bringing it to the front.
    ///
    /// Returns false only when Steam cannot be found at all; a successful launch says
    /// nothing about Steam being *ready*, which is why callers retry the API session
    /// rather than trusting this.
    @discardableResult
    static func launch() async -> Bool {
        guard let app = locate() else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
