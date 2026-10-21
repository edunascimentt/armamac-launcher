import SwiftUI

/// Shown when joining a server needs something first: mods to download, or a password.
struct JoinServerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let join: AppModel.PendingJoin
    @State private var password = ""
    @State private var isRetrying = false

    private var downloader: WorkshopDownloader { app.downloader }

    /// The server enforces BattlEye but the build we would launch cannot satisfy it.
    private var battlEyeBlocked: Bool {
        guard join.server.battlEye else { return false }
        guard let installation = app.selectedInstallation,
              let executable = installation.executable(
                  battlEye: true, prefer64Bit: app.settings.launchOptions.prefer64Bit
              )
        else { return false }
        return !executable.kind.supportsBattlEye
    }

    /// Recomputed against the live library so the sheet clears itself as mods arrive.
    private var stillMissing: [ServerMod] {
        let installed = app.browser.installedWorkshopIDs
        return join.missing.filter { !installed.contains($0.publishedFileID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if join.modListUnavailable {
                unknownModsSection
            }

            if battlEyeBlocked {
                Label(
                    """
                    This server requires BattlEye, which the Apple Silicon build of Arma 3 \
                    does not support. Install the standard (Intel) Mac build or run Arma \
                    through CrossOver to join.
                    """,
                    systemImage: "shield.slash"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !missingCreatorDLC.isEmpty {
                creatorDLCSection
            }

            if !stillMissing.isEmpty {
                missingModsSection
            }
            if join.server.isPasswordProtected {
                passwordSection
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
        .frame(maxHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(join.server.displayName)
                .font(.headline)
                .lineLimit(2)
            Text(join.server.address.description)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// The server did not answer its mod-list query, so joining is a guess either way.
    private var unknownModsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Could not read this server's mod list", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)

            Text("""
            The server did not answer the mod-list query, which busy servers often rate-limit. \
            Joining now would start the game with whatever is currently enabled — if the server \
            is modded, you would be kicked for missing addons.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if join.retryFailed {
                Label("Still no answer. The server may be full or blocking queries.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button {
                    isRetrying = true
                    Task { await app.retryModList(); isRetrying = false }
                } label: {
                    if isRetrying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading…")
                        }
                    } else {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)

                Button("Open in Steam") {
                    app.openInSteam(join.server.steamConnectURL)
                }
                .help("Let the Steam client handle the connection instead")
            }
        }
    }

    private var missingCreatorDLC: [ServerDLC] { app.missingCreatorDLC(for: join.server) }

    /// Creator DLC are paid content, so "download the missing mods" cannot help here.
    private var creatorDLCSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                missingCreatorDLC.count == 1
                    ? "This server needs a Creator DLC you do not have"
                    : "This server needs \(missingCreatorDLC.count) Creator DLC you do not have",
                systemImage: "bag"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)

            ForEach(missingCreatorDLC) { dlc in
                HStack(spacing: 6) {
                    Image(systemName: "star.square").font(.caption).foregroundStyle(.purple)
                    Text(dlc.name).lineLimit(1)
                    Spacer()
                    Button("View on Steam") {
                        app.openInSteam(URL(string: "steam://store/\(dlc.appID)"))
                    }
                    .buttonStyle(.link)
                }
                .font(.callout)
            }

            Text("Creator DLC are paid content — they cannot be downloaded from the Workshop.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var missingModsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(stillMissing.count) of \(join.server.mods.count) mods are not installed",
                systemImage: "arrow.down.circle"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)

            if downloader.isRunning || !downloader.items.isEmpty {
                downloadProgress
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(stillMissing) { mod in
                            HStack(spacing: 6) {
                                Image(systemName: "circle.dashed")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(mod.name.isEmpty
                                     ? "Workshop item \(mod.publishedFileID)" : mod.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(mod.publishedFileID))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 200)

                HStack(spacing: 10) {
                    Button {
                        app.downloadMissingMods(for: join, joinWhenReady: true)
                    } label: {
                        Label(
                            stillMissing.count == 1
                                ? "Install mod and join" : "Install \(stillMissing.count) mods and join",
                            systemImage: "arrow.down.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button("View on Workshop") {
                        for mod in stillMissing.prefix(5) {
                            app.openInSteam(
                                URL(string: "steam://url/CommunityFilePage/\(mod.publishedFileID)")
                            )
                        }
                    }
                }

                Label(
                    "Subscribes with your Steam client; Steam downloads them.",
                    systemImage: "arrow.down.app"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: downloader.overallProgress) {
                Text(downloader.statusMessage
                    ?? "\(downloader.completedCount) of \(downloader.items.count) items")
                    .font(.callout)
            }

            if downloader.isRunning {
                Text("The game starts by itself once every mod is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(downloader.items) { item in
                        DownloadRow(item: item)
                    }
                }
            }
            .frame(maxHeight: 180)

            if let error = downloader.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if downloader.isRunning {
                    Button("Cancel download") { downloader.cancel() }
                } else {
                    Button("Rescan mods") {
                        Task { await app.rescanMods() }
                    }
                }
            }
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This server is password protected", systemImage: "lock.fill")
                .font(.subheadline.weight(.medium))
            SecureField("Server password", text: $password)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack {
            Button("Match mods only") {
                app.applyServerModSelection(join.server)
                dismiss()
                app.pendingJoin = nil
            }
            .help("Set the load order to this server's mods without launching")

            Spacer()

            Button("Cancel") {
                dismiss()
                app.pendingJoin = nil
            }
            .keyboardShortcut(.cancelAction)

            Button {
                app.applyServerModSelection(join.server)
                app.join(server: join.server, password: password.isEmpty ? nil : password)
                dismiss()
            } label: {
                Label(
                    stillMissing.isEmpty && !join.modListUnavailable ? "Join" : "Join anyway",
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!app.canLaunch)
        }
    }
}

struct DownloadRow: View {
    let item: WorkshopDownloader.Item

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                if case .downloading = item.state {
                    if let fraction = item.fractionComplete {
                        ProgressView(value: fraction).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else if case let .failed(reason) = item.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if case let .skipped(reason) = item.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let expected = item.expectedBytes {
                Text(Format.bytes(expected))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.tertiary)
        case .downloading:
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "arrow.up.forward.square").foregroundStyle(.orange)
        }
    }
}
