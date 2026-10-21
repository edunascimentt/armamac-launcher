import SwiftUI

/// Compact download indicator for the top bar.
///
/// Downloads are occasional, so they get a small icon that only draws attention while
/// something is running; the full queue and its transcript live in a popover.
struct DownloadsChip: View {
    @Environment(AppModel.self) private var app
    @State private var showPopover = false

    private var downloader: WorkshopDownloader { app.downloader }

    private var hasActivity: Bool { downloader.isRunning || !downloader.items.isEmpty }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if downloader.isRunning {
                        // A determinate ring doubles as the icon while work is in flight.
                        Circle()
                            .stroke(.quaternary, lineWidth: 2)
                            .frame(width: 16, height: 16)
                        Circle()
                            .trim(from: 0, to: max(0.04, downloader.overallProgress))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 16, height: 16)
                            .rotationEffect(.degrees(-90))
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14))
                    }
                }
                .frame(width: 16, height: 16)

                if downloader.isRunning {
                    Text("\(downloader.completedCount)/\(downloader.items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                } else if downloader.lastError != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hasActivity ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DownloadsPopover()
                .environment(app)
        }
    }

    private var helpText: String {
        if downloader.isRunning {
            return "Downloading \(downloader.completedCount) of \(downloader.items.count) mods"
        }
        return downloader.items.isEmpty ? "Mod downloads" : "Last download queue"
    }
}
