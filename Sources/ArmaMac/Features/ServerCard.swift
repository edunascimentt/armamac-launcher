import SwiftUI

/// One server as a card, the way Arma's own launcher presents them: the name leads, and
/// everything needed to decide whether to join sits underneath it.
///
/// Cards also reflow, so unlike a column layout nothing is forced off the edge when the
/// window is narrow.
struct ServerCard: View {
    let server: GameServer
    let isFavourite: Bool
    let isLoadingMods: Bool
    /// Workshop ids already present locally, used to say whether the modset is ready.
    let installedMods: Set<UInt64>
    let toggleFavourite: () -> Void

    private var missingMods: Int {
        guard server.modsLoaded else { return 0 }
        return server.mods.count { !installedMods.contains($0.publishedFileID) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggleFavourite) {
                Image(systemName: isFavourite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavourite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                title
                subtitle
                badges
            }
            // Nothing here may impose a minimum width, or the whole list would push the
            // window's other columns off-screen.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()

            Spacer(minLength: 8)

            counters
        }
        .padding(.vertical, 7)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
    }

    private var title: some View {
        HStack(spacing: 5) {
            if server.isPasswordProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(server.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var subtitle: some View {
        HStack(spacing: 5) {
            Text(server.map.isEmpty ? server.address.host : server.map)
            if !server.gameDescription.isEmpty, server.gameDescription != server.map {
                Text("·")
                Text(server.gameDescription).lineLimit(1)
            }
            Text("·")
            Text(server.serverState.displayName)
            if !server.requiredVersion.isEmpty {
                Text("·")
                Text("v\(server.requiredVersion)")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 5) {
            if server.battlEye {
                CardBadge(text: "BattlEye", symbol: "shield.lefthalf.filled", tint: .green)
            }
            if server.verifySignatures {
                CardBadge(text: "Signed", symbol: "checkmark.seal", tint: .blue)
            }
            modBadge
            if !server.country.isEmpty {
                CardBadge(text: server.country, symbol: nil, tint: .secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var modBadge: some View {
        if isLoadingMods {
            CardBadge(text: "Reading mods…", symbol: "ellipsis", tint: .secondary)
        } else if !server.modsLoaded {
            CardBadge(text: "Mods unknown", symbol: "questionmark", tint: .secondary)
        } else if server.mods.isEmpty {
            CardBadge(text: "Vanilla", symbol: "checkmark.circle", tint: .secondary)
        } else if missingMods == 0 {
            CardBadge(
                text: "\(server.mods.count) mods · ready",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        } else {
            CardBadge(
                text: "\(server.mods.count) mods · \(missingMods) missing",
                symbol: "arrow.down.circle",
                tint: .orange
            )
        }
    }

    private var counters: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Text("\(server.players)")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Text("/ \(server.maxPlayers)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if server.maxPlayers > 0 {
                let fraction = min(1, Double(server.players) / Double(server.maxPlayers))
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: server.isFull ? .orange : .accentColor,
                                      location: fraction),
                                .init(color: Color.secondary.opacity(0.25), location: fraction),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: 54, height: 4)
            }

            PingBadge(ping: server.ping)
                .font(.system(size: 11))
        }
        .fixedSize()
    }
}

/// Small flag used inside a server card.
private struct CardBadge: View {
    let text: String
    let symbol: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}
