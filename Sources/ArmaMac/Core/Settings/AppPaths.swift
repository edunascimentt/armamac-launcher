import Foundation

/// Where the launcher keeps its own files.
enum AppPaths {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/ArmaMac")
    }

    /// Workshop content fetched by older builds through SteamCMD.
    ///
    /// Downloads no longer go here — Steam does the fetching now — but mods that landed
    /// here before still work, so the scanner keeps reading the folder.
    static var legacySteamCMDContent: URL {
        supportDirectory.appending(path: "steamcmd/steamapps/workshop/content/\(Arma3.appIDString)")
    }
}
