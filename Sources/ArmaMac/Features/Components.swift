import SwiftUI

/// Colour-coded round-trip time.
struct PingBadge: View {
    var ping: Duration?

    private var milliseconds: Int? {
        ping.map { Int($0.components.seconds * 1_000 + $0.components.attoseconds / 1_000_000_000_000_000) }
    }

    private var tint: Color {
        guard let milliseconds else { return .secondary }
        switch milliseconds {
        case ..<60: return .green
        case ..<120: return .yellow
        case ..<220: return .orange
        default: return .red
        }
    }

    var body: some View {
        if let milliseconds {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text("\(milliseconds)")
                    .monospacedDigit()
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// Small capsule label used for server flags and mod origins.
struct Pill: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// Players / max with a subtle capacity bar.
struct PlayerCountView: View {
    var players: Int
    var maxPlayers: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(players)/\(maxPlayers)")
                .monospacedDigit()
            if maxPlayers > 0 {
                // One shape per row: a gradient stop stands in for a second overlaid bar.
                let fraction = min(1, Double(players) / Double(maxPlayers))
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: players >= maxPlayers ? .orange : .accentColor,
                                      location: fraction),
                                .init(color: Color.secondary.opacity(0.25), location: fraction),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: 34, height: 4)
            }
        }
    }
}

struct ModOriginBadge: View {
    var origin: ModOrigin

    var body: some View {
        switch origin {
        case .workshop: Pill(text: "Workshop", systemImage: "cloud", tint: .blue)
        case .bundled: Pill(text: "Official", systemImage: "seal", tint: .purple)
        case .local: Pill(text: "Local", systemImage: "folder", tint: .gray)
        }
    }
}

/// Empty-state placeholder consistent across the app.
struct EmptyStateView: View {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

extension View {
    /// Liquid Glass where the system has it, a material where it does not, so the app's own
    /// surfaces sit in the same visual language as the chrome around them.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        // The formatter renders anything under a minute as "in 0 sec", which reads wrong.
        guard abs(date.timeIntervalSinceNow) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func duration(_ duration: Duration?) -> String {
        guard let duration else { return "—" }
        let total = Int(duration.components.seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
