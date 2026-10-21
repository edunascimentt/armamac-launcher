import SwiftUI

/// Detail pane for one mod: Workshop preview, metadata and folder actions.
struct ModInspector: View {
    @Environment(AppModel.self) private var app
    var mod: Mod?

    private var detail: WorkshopDetails? {
        mod.flatMap { app.library.detail(for: $0) }
    }

    var body: some View {
        Group {
            if let mod {
                content(mod)
            } else {
                EmptyStateView(
                    title: "No mod selected",
                    message: "Select a mod to see its Workshop details and folder.",
                    systemImage: "shippingbox"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ mod: Mod) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let preview = detail?.previewURL {
                    AsyncImage(url: preview) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().aspectRatio(contentMode: .fit)
                        case .failure:
                            Color.clear.frame(height: 0)
                        default:
                            Rectangle()
                                .fill(.quaternary)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .overlay { ProgressView().controlSize(.small) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(mod.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ModOriginBadge(origin: mod.origin)
                        if app.library.hasUpdate(mod) {
                            Pill(text: "Update available", systemImage: "arrow.triangle.2.circlepath", tint: .blue)
                        }
                        if detail?.isUnavailable == true {
                            Pill(text: "Delisted", systemImage: "eye.slash", tint: .orange)
                        }
                    }
                }

                Toggle("Enabled", isOn: Binding(
                    get: { app.library.isEnabled(mod) },
                    set: { app.library.setEnabled($0, for: mod) }
                ))
                .toggleStyle(.switch)

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Folder", mod.folderName)
                        row("Size", Format.bytes(mod.sizeOnDisk ?? detail?.fileSize))
                        if let author = mod.author { row("Author", author) }
                        if let version = mod.modVersion { row("Version", version) }
                        row("Updated", Format.relative(detail?.timeUpdated))
                        if let subscriptions = detail?.subscriptions {
                            row("Subscribers", subscriptions.formatted())
                        }
                        if let id = mod.publishedFileID {
                            row("Workshop ID", String(id))
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                HStack(spacing: 8) {
                    Button {
                        app.revealInFinder(mod.path)
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    if let url = mod.steamProtocolURL {
                        Button {
                            app.openInSteam(url)
                        } label: {
                            Label("Steam", systemImage: "arrow.up.forward.square")
                        }
                    }
                    if let id = mod.publishedFileID {
                        Button {
                            app.download(ids: [id], names: [id: mod.name])
                        } label: {
                            Label("Update", systemImage: "arrow.down.circle")
                        }
                    }
                }
                .controlSize(.small)

                if let description = detail?.descriptionText ?? mod.descriptionText,
                   !description.isEmpty {
                    GroupBox("Description") {
                        Text(Self.stripBBCode(description))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }

                Text(mod.path.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    /// Workshop descriptions are BBCode; render them as plain text rather than markup soup.
    static func stripBBCode(_ text: String) -> String {
        let pattern = #"\[/?[^\]]{1,30}\]"#
        let stripped = text.replacingOccurrences(
            of: pattern, with: "", options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
