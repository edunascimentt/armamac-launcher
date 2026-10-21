import SwiftUI

/// Right-hand detail pane for the selected server: flags, mod list with install state,
/// and the player list.
struct ServerInspector: View {
    @Environment(AppModel.self) private var app
    var server: GameServer?

    var body: some View {
        Group {
            if let server {
                content(for: server)
            } else {
                EmptyStateView(
                    title: "No server selected",
                    message: "Pick a server to see its mods, players and settings.",
                    systemImage: "sidebar.trailing"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for server: GameServer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(server)
                flagsSection(server)
                modsSection(server)
                playersSection(server)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: server.address) {
            // Keyed on the player list, not the mods: the background sweep marks every
            // server as having its mods read, which used to short-circuit this and leave
            // the player list permanently empty.
            guard !server.playersLoaded else { return }
            await app.browser.refreshDetails(for: server.address, settings: app.settings)
        }
    }

    private func headerSection(_ server: GameServer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(server.displayName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(server.address.description)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0)
                Button {
                    app.copyToPasteboard(server.address.description)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy address")
            }

            // Side by side these two overflow the narrowest inspector width, so they wrap.
            FlowRow(spacing: 14) {
                LabeledContent("Players") {
                    PlayerCountView(players: server.players, maxPlayers: server.maxPlayers)
                }
                LabeledContent("Ping") { PingBadge(ping: server.ping) }
            }
            .font(.callout)

            Button {
                Task { await app.prepareJoin(server: server) }
            } label: {
                Label("Join server", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func flagsSection(_ server: GameServer) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                detailRow("Map", server.map.isEmpty ? "—" : server.map)
                detailRow("Status", server.serverState.displayName)
                detailRow("Version", server.version.isEmpty ? "—" : server.version)
                if !server.requiredVersion.isEmpty {
                    detailRow("Requires", server.requiredVersion)
                }
                detailRow("Platform", server.os.isEmpty ? "—" : server.os)
                if let timeLeft = server.timeLeft {
                    detailRow("Time left", Format.duration(timeLeft))
                }

                FlowRow(spacing: 5) {
                    if server.battlEye {
                        Pill(text: "BattlEye", systemImage: "shield.lefthalf.filled", tint: .green)
                    }
                    if server.verifySignatures {
                        Pill(text: "Signed mods", systemImage: "checkmark.seal", tint: .blue)
                    }
                    if server.isPasswordProtected {
                        Pill(text: "Password", systemImage: "lock.fill", tint: .orange)
                    }
                    if server.equalModRequired {
                        Pill(text: "Exact modset", systemImage: "equal.circle", tint: .purple)
                    }
                    if server.allowedFilePatching {
                        Pill(text: "File patching", systemImage: "doc.badge.gearshape", tint: .gray)
                    }
                    if server.isVAC {
                        Pill(text: "VAC", systemImage: "shield", tint: .secondary)
                    }
                }
                .padding(.top, 2)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private func modsSection(_ server: GameServer) -> some View {
        let installed = app.browser.installedWorkshopIDs
        let missing = server.mods.filter { !installed.contains($0.publishedFileID) }

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Mods").font(.headline)
                    Spacer()
                    if app.browser.loadingRules.contains(server.address) {
                        ProgressView().controlSize(.mini)
                    } else if server.modsLoaded {
                        Text("\(server.mods.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                if !server.modsLoaded {
                    Button("Load mod list") {
                        Task {
                            await app.browser.refreshDetails(
                                for: server.address, settings: app.settings
                            )
                        }
                    }
                    .buttonStyle(.link)
                } else if server.mods.isEmpty {
                    Text("Vanilla — no mods required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if !missing.isEmpty {
                        Label(
                            "\(missing.count) not installed",
                            systemImage: "arrow.down.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)

                        Button("Download missing mods") {
                            app.download(
                                ids: missing.map(\.publishedFileID),
                                names: Dictionary(
                                    missing.map { ($0.publishedFileID, $0.name) },
                                    uniquingKeysWith: { first, _ in first }
                                )
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    ForEach(server.mods) { mod in
                        HStack(spacing: 6) {
                            Image(
                                systemName: installed.contains(mod.publishedFileID)
                                    ? "checkmark.circle.fill" : "circle.dashed"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                installed.contains(mod.publishedFileID) ? .green : .orange
                            )
                            Text(mod.name.isEmpty ? "Workshop item \(mod.publishedFileID)" : mod.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 0)
                            Spacer()
                            Button {
                                app.openInSteam(
                                    URL(string: "steam://url/CommunityFilePage/\(mod.publishedFileID)")
                                )
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("Open on Steam Workshop")
                        }
                        .font(.callout)
                    }

                    Button("Use exactly these mods") {
                        app.applyServerModSelection(server)
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }

                if !server.dlcs.isEmpty {
                    Divider()
                    Text("DLC").font(.subheadline.weight(.medium))
                    ForEach(server.dlcs) { dlc in
                        HStack(spacing: 6) {
                            Image(systemName: dlc.isCreatorDLC ? "star.square" : "square.stack.3d.up")
                                .font(.caption)
                                .foregroundStyle(.purple)
                            Text(dlc.name).lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private func playersSection(_ server: GameServer) -> some View {
        if server.playersLoaded, server.playerList.isEmpty, server.players > 0 {
            GroupBox {
                Text("The server did not share its player list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        } else if !server.playerList.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Players").font(.headline)
                    ForEach(server.playerList) { player in
                        HStack {
                            Text(player.name.isEmpty ? "(connecting)" : player.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 0)
                            Spacer()
                            Text(Format.duration(player.duration))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(minWidth: 0)
        }
    }
}

/// Wraps its children onto as many lines as needed — used for the flag pills.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth,
                      height: totalHeight + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
