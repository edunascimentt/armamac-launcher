import SwiftUI

/// The download queue, shown from the top-bar chip rather than a whole tab.
struct DownloadsPopover: View {
    @Environment(AppModel.self) private var app
    @State private var showLog = false
    @State private var manualIDs = ""

    private var downloader: WorkshopDownloader { app.downloader }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if downloader.items.isEmpty {
                Text("""
                Downloads start when you join a server that needs mods, import a collection, \
                or pick Update on a mod.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                if downloader.isRunning || downloader.completedCount > 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: downloader.overallProgress)
                        HStack {
                            Text(downloader.statusMessage
                                ?? "\(downloader.completedCount) of \(downloader.items.count) items")
                            Spacer()
                            if downloader.expectedBytes > 0 {
                                Text("\(Format.bytes(downloader.downloadedBytes)) of "
                                    + Format.bytes(downloader.expectedBytes))
                                    .monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(downloader.items) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if let error = downloader.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            manualEntry

            if showLog, !downloader.log.isEmpty { logPane }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Label("Mod downloads", systemImage: "arrow.down.circle")
                .font(.headline)
            Spacer()
            Pill(
                text: SteamClientApp.isRunning ? "Steam client" : "Steam not running",
                systemImage: "arrow.up.forward.app",
                tint: SteamClientApp.isRunning ? .green : .orange
            )
        }
    }

    private var manualEntry: some View {
        HStack(spacing: 8) {
            TextField("Workshop IDs or URLs", text: $manualIDs)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                let ids = manualIDs
                    .split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline })
                    .compactMap { PresetHTML.workshopID(fromURL: String($0)) ?? UInt64($0) }
                manualIDs = ""
                app.download(ids: ids)
            }
            .disabled(manualIDs.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
    }

    private var logPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(downloader.log.suffix(200).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(6)
        }
        .frame(height: 140)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            Button(showLog ? "Hide log" : "Show log") { showLog.toggle() }
                .disabled(downloader.log.isEmpty)
            Spacer()
            if downloader.isRunning {
                Button("Cancel", role: .destructive) { downloader.cancel() }
            } else {
                Button("Rescan mods") { Task { await app.rescanMods() } }
            }
        }
        .controlSize(.small)
    }
}
