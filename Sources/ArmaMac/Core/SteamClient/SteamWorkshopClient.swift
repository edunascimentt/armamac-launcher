import Foundation

/// Installs Workshop mods the way the Workshop page's Subscribe button does: it asks the
/// running Steam client to subscribe, Steam downloads the item itself, and this type just
/// watches the progress.
///
/// No SteamCMD, no credentials, no second copy of the mod — items land in the normal Steam
/// workshop folder that the mod scanner already reads.
@MainActor
final class SteamWorkshopClient {
    struct ItemStatus: Sendable, Equatable {
        var publishedFileID: UInt64
        var state: UInt32
        var bytesDownloaded: Int64
        var bytesTotal: Int64
        var sizeOnDisk: Int64
        var installPath: URL?

        var isSubscribed: Bool { state & UInt32(ArmaMacWorkshopStateSubscribed.rawValue) != 0 }
        var isInstalled: Bool { state & UInt32(ArmaMacWorkshopStateInstalled.rawValue) != 0 }
        var needsUpdate: Bool { state & UInt32(ArmaMacWorkshopStateNeedsUpdate.rawValue) != 0 }
        var isDownloading: Bool { state & UInt32(ArmaMacWorkshopStateDownloading.rawValue) != 0 }
        var isPending: Bool { state & UInt32(ArmaMacWorkshopStateDownloadPending.rawValue) != 0 }

        /// Installed and not waiting on anything else.
        var isReady: Bool { isInstalled && !needsUpdate && !isDownloading && !isPending }

        var fractionComplete: Double? {
            guard bytesTotal > 0 else { return nil }
            return min(1, Double(bytesDownloaded) / Double(bytesTotal))
        }
    }

    enum ClientError: Error, LocalizedError {
        case noDylib
        case sessionFailed(String)
        case subscribeFailed(UInt64, String)

        var errorDescription: String? {
            switch self {
            case .noDylib:
                """
                Could not find Steam's libsteam_api.dylib, which ships with Arma 3. \
                Install the game (or point ArmaMac at the install) to subscribe from here.
                """
            case let .sessionFailed(message): message
            case let .subscribeFailed(id, message): "Could not subscribe to \(id): \(message)"
            }
        }
    }

    private(set) var isSessionOpen = false

    /// Opens a Steam session. Steam shows the app as running the game while this is open,
    /// so it is closed as soon as downloads finish or the game is launched.
    func beginSession(dylib: URL) throws {
        guard !isSessionOpen else { return }
        let opened = dylib.path(percentEncoded: false).withCString { path in
            armamac_steam_session_begin(path, UInt32(Arma3.appID))
        }
        guard opened else {
            throw ClientError.sessionFailed(String(cString: armamac_steam_last_error()))
        }
        isSessionOpen = true
    }

    /// Releases this client's reference. The session stays open if something else — a
    /// server-list refresh, say — still holds one.
    func endSession() {
        guard isSessionOpen else { return }
        armamac_steam_session_end()
        isSessionOpen = armamac_steam_session_active()
    }

    /// Tears the session down regardless of other holders.
    ///
    /// Used before launching the game, where an open session would make Steam believe Arma
    /// is already running, and when the user cancels.
    func forceEndSession() {
        armamac_steam_session_end_all()
        isSessionOpen = false
    }

    /// Subscribes to an item; Steam queues and performs the download.
    @discardableResult
    func subscribe(_ publishedFileID: UInt64) throws -> Bool {
        guard isSessionOpen else {
            throw ClientError.sessionFailed("No Steam session is open.")
        }
        guard armamac_steam_subscribe_item(publishedFileID) else {
            throw ClientError.subscribeFailed(
                publishedFileID, String(cString: armamac_steam_last_error())
            )
        }
        return true
    }

    func unsubscribe(_ publishedFileID: UInt64) {
        _ = armamac_steam_unsubscribe_item(publishedFileID)
    }

    /// Asks Steam to (re)start the download for an item it already knows about.
    ///
    /// `SubscribeItem` is asynchronous, so the download nudge that follows it can land
    /// before Steam has registered the subscription. Re-issuing it while the item sits
    /// idle is what turns a subscribed-but-untouched item into an actual download.
    @discardableResult
    func requestDownload(_ publishedFileID: UInt64) -> Bool {
        armamac_steam_download_item(publishedFileID, true)
    }

    /// Pumps Steam's callbacks; must be called regularly while downloads run.
    func runCallbacks() {
        armamac_steam_run_callbacks()
    }

    func status(of publishedFileID: UInt64) -> ItemStatus? {
        var raw = ArmaMacWorkshopItemStatus()
        guard armamac_steam_item_status(publishedFileID, &raw) else { return nil }

        let path = withUnsafeBytes(of: raw.installPath) { buffer -> URL? in
            let bytes = buffer.prefix { $0 != 0 }
            guard !bytes.isEmpty else { return nil }
            return URL(filePath: String(decoding: bytes, as: UTF8.self))
        }

        return ItemStatus(
            publishedFileID: publishedFileID,
            state: raw.state,
            bytesDownloaded: Int64(raw.bytesDownloaded),
            bytesTotal: Int64(raw.bytesTotal),
            sizeOnDisk: Int64(raw.sizeOnDisk),
            installPath: path
        )
    }
}
