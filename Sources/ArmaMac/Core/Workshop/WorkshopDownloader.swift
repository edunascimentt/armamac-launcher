import AppKit
import Foundation
import Observation

/// Queues Workshop installs and reports progress to the UI.
///
/// There is one route and it needs nothing from the user: the launcher asks the running
/// Steam client to subscribe — the same thing the Workshop page's Subscribe button does —
/// and Steam downloads the item into the normal workshop folder the mod scanner reads.
/// No credentials, no second tool, no second copy of the mod.
///
/// If Steam is not running it is started, and the API session is retried until Steam is
/// ready to answer, so a cold machine still ends up installing the mods on its own.
@MainActor
@Observable
final class WorkshopDownloader {
    enum ItemState: Equatable, Sendable {
        case queued
        case downloading
        case finished(URL?)
        case failed(String)
        case skipped(String)

        var isTerminal: Bool {
            switch self {
            case .finished, .failed, .skipped: true
            case .queued, .downloading: false
            }
        }
    }

    struct Item: Identifiable, Sendable {
        var id: UInt64
        var name: String
        var state: ItemState = .queued
        var expectedBytes: Int64?
        var downloadedBytes: Int64 = 0

        var fractionComplete: Double? {
            guard let expectedBytes, expectedBytes > 0 else { return nil }
            return min(1, Double(downloadedBytes) / Double(expectedBytes))
        }
    }

    // MARK: - Observable state

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var log: [String] = []
    private(set) var currentItemID: UInt64?
    var lastError: String?

    /// What the queue is doing right now, for the chip and the join sheet.
    private(set) var statusMessage: String?

    var completedCount: Int { items.filter { $0.state.isTerminal }.count }

    /// Items that finished this run, for callers waiting to act on a completed install.
    var installedIDs: Set<UInt64> {
        Set(items.filter { if case .finished = $0.state { true } else { false } }.map(\.id))
    }

    /// Bytes fetched so far, and the total expected, when Steam has reported sizes.
    var downloadedBytes: Int64 { Self.downloadedBytes(of: items) }
    var expectedBytes: Int64 { Self.expectedBytes(of: items) }
    var overallProgress: Double { Self.progress(of: items) }

    // The progress maths is pure, so it can be reasoned about — and tested — without a
    // running Steam client.

    nonisolated static func downloadedBytes(of items: [Item]) -> Int64 {
        items.reduce(0) { $0 + $1.downloadedBytes }
    }

    nonisolated static func expectedBytes(of items: [Item]) -> Int64 {
        items.reduce(0) { $0 + ($1.expectedBytes ?? 0) }
    }

    /// Aggregate progress.
    ///
    /// Steam downloads several items at once, so following a single "current" item made the
    /// bar jump around. Bytes are used when known, falling back to a count of finished items.
    nonisolated static func progress(of items: [Item]) -> Double {
        guard !items.isEmpty else { return 0 }
        let expected = expectedBytes(of: items)
        if expected > 0 {
            return min(1, Double(downloadedBytes(of: items)) / Double(expected))
        }
        let finished = items.count { $0.state.isTerminal }
        return min(1, Double(finished) / Double(items.count))
    }

    private let api = SteamWorkshopAPI()
    private let steamClient = SteamWorkshopClient()
    private var runTask: Task<Void, Never>?

    /// Path to `libsteam_api.dylib`; set once installs are known.
    var steamDylib: URL?

    /// Called when a run ends, however it ended, so the library can be rescanned.
    var onFinished: (@MainActor () -> Void)?

    /// How long to keep waiting for Steam to come up before giving up on it.
    private let steamStartupTimeout = Duration.seconds(90)
    /// How long an item may sit with no progress at all before it is called stalled.
    private let inactivityLimit = Duration.seconds(300)
    /// How often an idle subscribed item is nudged back into Steam's download queue.
    private let nudgeInterval = Duration.seconds(5)

    // MARK: - Queueing

    /// Replaces the queue with the given items and starts downloading.
    func start(ids: [UInt64], names: [UInt64: String] = [:]) {
        guard !isRunning, !ids.isEmpty else { return }
        items = ids.uniqued().map { Item(id: $0, name: names[$0] ?? "Workshop item \($0)") }
        log.removeAll()
        lastError = nil
        isRunning = true
        statusMessage = "Preparing…"

        runTask = Task { [weak self] in
            guard let self else { return }
            await run()
            isRunning = false
            currentItemID = nil
            statusMessage = nil
            onFinished?()
        }
    }

    /// Drops any Steam session before the game starts, so Steam does not treat the
    /// launcher's session as "Arma is already running".
    func releaseSteamSession() {
        steamClient.forceEndSession()
    }

    func cancel() {
        runTask?.cancel()
        steamClient.forceEndSession()
        isRunning = false
        currentItemID = nil
        statusMessage = nil
        append(log: "Cancelled.")
    }

    // MARK: - The run

    private func run() async {
        guard let steamDylib else {
            fail(SteamWorkshopClient.ClientError.noDylib.localizedDescription)
            return
        }

        guard await openSession(dylib: steamDylib) else { return }
        // Steam counts the app as running the game while the session is open.
        defer { steamClient.endSession() }

        // Sizes make the progress bars meaningful before Steam reports any bytes.
        statusMessage = "Looking up \(items.count) item(s)…"
        if let details = try? await api.details(for: items.map(\.id)) {
            for index in items.indices {
                if let detail = details[items[index].id] {
                    items[index].expectedBytes = detail.fileSize
                    if !detail.title.isEmpty { items[index].name = detail.title }
                }
            }
        }
        guard !Task.isCancelled else { return }

        append(log: "Subscribing to \(items.count) Workshop item(s)…")
        statusMessage = "Subscribing…"
        var subscribed = 0
        for index in items.indices {
            guard !Task.isCancelled else { return }
            let item = items[index]
            do {
                try steamClient.subscribe(item.id)
                items[index].state = .downloading
                subscribed += 1
                append(log: "Subscribed to \(item.name) (\(item.id))")
            } catch {
                items[index].state = .failed(error.localizedDescription)
                append(log: "Failed to subscribe to \(item.id): \(error.localizedDescription)")
            }
            steamClient.runCallbacks()
        }

        guard subscribed > 0 else {
            fail("Steam refused every subscription. Check that the signed-in Steam account "
                + "owns Arma 3.")
            return
        }

        await watchSteamDownloads()
    }

    /// Opens the Steam API session, starting Steam and waiting for it when necessary.
    ///
    /// Steam refuses API connections until it has finished signing in, so a launcher that
    /// only tried once would fail on exactly the machines that need the most help: the
    /// ones where Steam was not up yet.
    private func openSession(dylib: URL) async -> Bool {
        var lastFailure: String
        do {
            try steamClient.beginSession(dylib: dylib)
            return true
        } catch {
            lastFailure = error.localizedDescription
        }

        if !SteamClientApp.isRunning {
            append(log: "Steam is not running — starting it.")
            guard await SteamClientApp.launch() else {
                fail("Steam is not running and could not be found. Start Steam, sign in, "
                    + "and try again.")
                return false
            }
        }

        append(log: "Waiting for Steam to be ready…")
        statusMessage = "Waiting for Steam…"
        let deadline = ContinuousClock.now + steamStartupTimeout
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .seconds(2))
            do {
                try steamClient.beginSession(dylib: dylib)
                append(log: "Steam is ready.")
                return true
            } catch {
                lastFailure = error.localizedDescription
            }
        }

        fail("Steam did not answer: \(lastFailure)")
        return false
    }

    /// Polls Steam until every subscribed item is installed, or nothing is moving.
    private func watchSteamDownloads() async {
        var lastActivity = ContinuousClock.now
        var lastNudge = ContinuousClock.now
        var lastTotalBytes: Int64 = -1
        var lastStates: [UInt64: UInt32] = [:]
        var warnedAboutQueue = false

        while !Task.isCancelled {
            steamClient.runCallbacks()

            var outstanding = 0
            var totalBytes: Int64 = 0
            var readable = 0
            var pending = 0
            var moving = false
            var idle: [UInt64] = []

            for index in items.indices {
                let id = items[index].id
                if case .failed = items[index].state { continue }
                pending += 1

                guard let status = steamClient.status(of: id) else { continue }
                readable += 1
                totalBytes += status.bytesDownloaded

                if lastStates.updateValue(status.state, forKey: id) != status.state {
                    moving = true
                }

                if status.isReady {
                    if !items[index].state.isTerminal {
                        items[index].state = .finished(status.installPath)
                        // Steam stops reporting download bytes the moment an item is
                        // installed, so the finished size is what keeps the bar full
                        // rather than snapping back.
                        if status.sizeOnDisk > 0 {
                            items[index].expectedBytes = status.sizeOnDisk
                            items[index].downloadedBytes = status.sizeOnDisk
                        } else if let expected = items[index].expectedBytes {
                            items[index].downloadedBytes = expected
                        }
                        append(log: "Installed \(items[index].name)")
                    }
                    continue
                }

                outstanding += 1
                items[index].state = .downloading
                if status.bytesTotal > 0 {
                    items[index].expectedBytes = status.bytesTotal
                    items[index].downloadedBytes = status.bytesDownloaded
                }
                if status.isDownloading || status.isPending {
                    moving = true
                    currentItemID = id
                } else {
                    // Subscribed (or not even that yet) but Steam is not fetching it.
                    idle.append(id)
                }
            }

            // Reading nothing is not the same as everything being done: if Steam quit or
            // the session dropped, every status query fails and reporting success would
            // leave the queue untouched.
            if readable == 0, pending > 0 {
                for index in items.indices where !items[index].state.isTerminal {
                    items[index].state = .failed("Steam stopped responding.")
                }
                fail("Lost contact with the Steam client. Check that Steam is still running.")
                return
            }

            if outstanding == 0 {
                append(log: "All items installed.")
                statusMessage = nil
                return
            }

            statusMessage = "Downloading \(outstanding) of \(items.count) in Steam…"

            // `SubscribeItem` is asynchronous, so the first download request often arrives
            // before Steam has recorded the subscription. Re-asking is what actually gets
            // a stuck item moving.
            if !idle.isEmpty, ContinuousClock.now - lastNudge >= nudgeInterval {
                lastNudge = .now
                for id in idle { steamClient.requestDownload(id) }
            }

            if totalBytes != lastTotalBytes {
                lastTotalBytes = totalBytes
                moving = true
            }
            if moving { lastActivity = .now }

            let idleFor = ContinuousClock.now - lastActivity
            if idleFor >= .seconds(30), !warnedAboutQueue {
                warnedAboutQueue = true
                append(log: "Waiting on Steam — the download may be queued behind another "
                    + "one in the Steam client.")
            }
            if idleFor >= inactivityLimit {
                for index in items.indices where !items[index].state.isTerminal {
                    items[index].state = .skipped("Still queued in Steam.")
                }
                fail("Steam has not started these downloads. Open the Steam client's "
                    + "Downloads tab to see what is holding them up; they will keep "
                    + "downloading there.")
                return
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Logging

    private func append(log line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func fail(_ message: String) {
        lastError = message
        statusMessage = nil
        append(log: "Error: \(message)")
    }
}
