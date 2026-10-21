import Foundation

/// Fetches the Arma 3 community server list from the **running Steam client**.
///
/// This is how the official launcher does it, and it needs no Steam Web API key: Steam
/// itself holds the master list, and `libsteam_api.dylib` (which ships inside the Arma app
/// bundles) exposes it. Requires Steam to be running and signed in to an account that owns
/// Arma 3.
struct SteamClientServerList: Sendable {
    enum ListError: Error, LocalizedError {
        case dylibNotFound
        case steamNotRunning(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .dylibNotFound:
                """
                Could not find Steam's libsteam_api.dylib. It ships with Arma 3, so \
                installing the game (or pointing ArmaMac at the install) enables the \
                server list.
                """
            case let .steamNotRunning(message):
                message
            case let .failed(message):
                message
            }
        }
    }

    var appID: UInt32 = UInt32(Arma3.appID)
    /// How long to let Steam keep streaming servers in. The list grows the whole time.
    var timeout: TimeInterval = 8

    /// Where `libsteam_api.dylib` might live, best candidate first.
    static func locateDylib(installations: [GameInstallation]) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        for installation in installations {
            for executable in installation.executables where executable.kind.isNative {
                candidates.append(
                    executable.url.appending(path: "Contents/MacOS/libsteam_api.dylib")
                )
            }
            candidates.append(installation.directory.appending(path: "libsteam_api.dylib"))
        }

        // A Windows install under Wine has no macOS dylib, but another native Steam game
        // on this Mac will do just as well — the library is app-agnostic.
        for installation in installations {
            let common = installation.library.common
            if let games = try? fileManager.contentsOfDirectory(
                at: common, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) {
                for game in games.prefix(40) {
                    candidates.append(game.appending(path: "libsteam_api.dylib"))
                }
            }
        }

        return candidates.first {
            fileManager.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// Runs the (blocking) Steam query off the cooperative pool and maps the results.
    func fetch(dylib: URL) async throws -> [(ServerAddress, GameServer)] {
        let path = dylib.path(percentEncoded: false)
        let appID = self.appID
        let timeout = self.timeout

        let rows: [ArmaMacSteamServer] = try await withCheckedThrowingContinuation { continuation in
            // Steam's API is not thread-safe, so every call is funnelled through one queue.
            Self.queue.async {
                var buffer: UnsafeMutablePointer<ArmaMacSteamServer>?
                let count = path.withCString { cPath in
                    armamac_steam_fetch_servers(cPath, appID, timeout, &buffer)
                }

                guard count >= 0 else {
                    let message = String(cString: armamac_steam_last_error())
                    if count == ArmaMacSteamErrorInitFailed.rawValue {
                        continuation.resume(throwing: ListError.steamNotRunning(message))
                    } else {
                        continuation.resume(throwing: ListError.failed(message))
                    }
                    return
                }

                var results: [ArmaMacSteamServer] = []
                if let buffer, count > 0 {
                    results = Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
                }
                armamac_steam_free(buffer)
                continuation.resume(returning: results)
            }
        }

        return rows.compactMap(Self.makeServer)
    }

    private static let queue = DispatchQueue(label: "com.armamac.launcher.steamclient")

    /// Converts one Steam row into the launcher's model.
    static func makeServer(_ row: ArmaMacSteamServer) -> (ServerAddress, GameServer)? {
        guard row.ip != 0, row.gamePort != 0 else { return nil }

        let host = "\(row.ip >> 24 & 0xFF).\(row.ip >> 16 & 0xFF).\(row.ip >> 8 & 0xFF).\(row.ip & 0xFF)"
        let address = ServerAddress(
            host: host,
            gamePort: row.gamePort,
            queryPort: row.queryPort == 0 ? row.gamePort &+ 1 : row.queryPort
        )

        var server = GameServer(address: address)
        server.name = text(row.name)
        server.map = text(row.map)
        server.gameDescription = text(row.gameDescription)
        // Steam counts bots in the player total, same as A2S.
        server.players = max(0, Int(row.players) - Int(row.botPlayers))
        server.maxPlayers = Int(row.maxPlayers)
        server.botCount = Int(row.botPlayers)
        server.isPasswordProtected = row.passwordProtected
        server.isVAC = row.secure
        // Steam reports 2000 ms for servers it could not reach.
        if row.ping > 0, row.ping < 2_000 {
            server.ping = .milliseconds(Int(row.ping))
        }
        // Arma packs the same keyword string Steam shows as "game tags", so BattlEye,
        // signature checking and server state are known without any query of our own.
        server.applyKeywords(ArmaKeywords(text(row.gameTags)))
        server.lastRefreshed = .now
        return (address, server)
    }

    /// Reads a fixed-size C char array as a String.
    private static func text<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
