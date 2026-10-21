import SwiftUI

/// The Profile section: which Arma profile the game starts as, and the settings that live
/// inside that profile — field of view and the headline video options.
///
/// Arma owns these files, so everything here is edited against a copy and written on Apply.
struct ProfileView: View {
    @Environment(AppModel.self) private var app

    @State private var sheet: ProfileSheet?
    @State private var pendingName = ""
    @State private var copySource: ArmaProfile?
    @State private var deleteCandidate: ArmaProfile?

    /// Sliders drive local drafts, not the model.
    ///
    /// Writing the observable model on every drag tick invalidated the rows around the
    /// slider — `markDirty()` alone flips `isDirty`, which the Apply row reads — and the
    /// resulting re-layout cancelled the drag, so the thumb never moved. The draft is
    /// committed when the drag ends instead.
    @State private var fovDraft = FieldOfView.arma3Default.horizontalDegrees
    @State private var viewDistanceDraft: Double = 1_600
    @State private var objectDistanceDraft: Double = 1_200

    private var model: GameSettingsModel { app.gameSettings }

    /// The three name-entry flows share one sheet.
    private enum ProfileSheet: String, Identifiable {
        case create, duplicate, rename
        var id: String { rawValue }

        var title: String {
            switch self {
            case .create: "New profile"
            case .duplicate: "Duplicate profile"
            case .rename: "Rename profile"
            }
        }

        var confirmTitle: String {
            switch self {
            case .create: "Create"
            case .duplicate: "Duplicate"
            case .rename: "Rename"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            applyBar
        }
        .onAppear { model.refresh(installation: app.selectedInstallation) }
        .onChange(of: model.horizontalFOV, initial: true) { _, value in
            if abs(value - fovDraft) > 0.001 { fovDraft = value }
        }
        .onChange(of: model.viewDistance, initial: true) { _, value in
            if abs(value - viewDistanceDraft) > 0.5 { viewDistanceDraft = value }
        }
        .onChange(of: model.objectViewDistance, initial: true) { _, value in
            if abs(value - objectDistanceDraft) > 0.5 { objectDistanceDraft = value }
        }
        .sheet(item: $sheet) { sheet in nameSheet(sheet) }
        .alert(
            "Delete “\(deleteCandidate?.name ?? "")”?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Move to Trash", role: .destructive) {
                if let profile = deleteCandidate {
                    model.deleteProfile(profile, installation: app.selectedInstallation)
                }
                deleteCandidate = nil
            }
        } message: {
            Text("The profile folder goes to the Trash, so you can put it back if needed.")
        }
    }

    private var form: some View {
        @Bindable var model = app.gameSettings

        return Form {
            Section("Profiles") {
                profileControls
            }

            Section("Field of view") {
                fovControls
            }

            if model.hasVideoConfig {
                Section("Video") {
                    videoControls
                }
            } else if model.selectedProfile != nil {
                Section("Video") {
                    Text("""
                    Arma3.cfg has not been written yet, so video settings are unavailable. \
                    Launch the game once and they will appear here.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Profiles

    @ViewBuilder
    private var profileControls: some View {
        @Bindable var model = app.gameSettings

        if model.profiles.isEmpty {
            Text("""
            No Arma profile found. Arma writes one the first time it runs — or create one \
            now so these settings apply to your first launch.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Create default profile") {
                    model.createDefaultProfile(installation: app.selectedInstallation)
                }
                .buttonStyle(.borderedProminent)
                Button("New named profile…") { present(.create) }
            }
        } else {
            Picker("Profile", selection: $model.selectedProfile) {
                ForEach(model.profiles) { profile in
                    Text(profile.displayName).tag(Optional(profile))
                }
            }

            if let profile = model.selectedProfile {
                LabeledContent("Launches as") {
                    if isLaunchProfile(profile) {
                        Label("Used on launch", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("Use for launch") { useForLaunch(profile) }
                            .controlSize(.small)
                    }
                }

                LabeledContent("File") {
                    Text(profile.profileURL.path(percentEncoded: false))
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }

            HStack {
                Button("New…") { present(.create) }
                Button("Duplicate…") { present(.duplicate) }
                    .disabled(model.selectedProfile == nil)
                Button("Rename…") { present(.rename) }
                    .disabled(model.selectedProfile == nil)
                Spacer()
                Button("Delete…", role: .destructive) {
                    deleteCandidate = model.selectedProfile
                }
                .disabled(model.selectedProfile.map(\.isDefault) ?? true)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Field of view

    /// What the slider is currently showing, before it is committed.
    private var draftFOV: FieldOfView {
        FieldOfView(horizontalDegrees: fovDraft, aspectRatio: model.aspectRatio)
    }

    @ViewBuilder
    private var fovControls: some View {
        @Bindable var model = app.gameSettings

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Horizontal")
                Spacer()
                Text("\(fovDraft, specifier: "%.1f")°")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $fovDraft,
                in: FieldOfView.minimumHorizontal...FieldOfView.maximumHorizontal,
                step: 0.5,
                onEditingChanged: { editing in
                    // Commit once, when the drag ends.
                    if !editing { commitFOV() }
                }
            )
            .labelsHidden()
            HStack {
                Text("\(Int(FieldOfView.minimumHorizontal))°")
                Spacer()
                Text("\(Int(FieldOfView.maximumHorizontal))°")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        LabeledContent("Presets") {
            HStack(spacing: 6) {
                ForEach(FieldOfView.presets, id: \.name) { preset in
                    Button(preset.name) {
                        fovDraft = preset.horizontal
                        commitFOV()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(preset.detail)
                }
            }
        }

        Picker("Aspect ratio", selection: $model.aspectRatio) {
            ForEach(FieldOfView.commonAspectRatios, id: \.value) { ratio in
                Text(ratio.name).tag(ratio.value)
            }
            // Keep whatever the profile already had, even if it is unusual.
            if !FieldOfView.commonAspectRatios.contains(where: {
                abs($0.value - model.aspectRatio) < 0.001
            }) {
                Text(model.currentFOV.aspectRatioName).tag(model.aspectRatio)
            }
        }
        .onChange(of: model.aspectRatio) { _, _ in model.markDirty() }

        LabeledContent("Vertical") {
            Text("\(draftFOV.verticalDegrees, specifier: "%.1f")°")
                .monospacedDigit()
        }

        // The two numbers that actually land in the profile.
        LabeledContent("Writes") {
            Text("fovTop=\(draftFOV.fovTopText)  fovLeft=\(draftFOV.fovLeftText)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }

        Text("""
        Arma stores the FOV as two tangents rather than degrees, and they must match your \
        display's shape or the picture stretches. Pick the ratio and ArmaMac computes both \
        values.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func commitFOV() {
        guard abs(model.horizontalFOV - fovDraft) > 0.001 else { return }
        model.horizontalFOV = fovDraft
        model.markDirty()
    }

    // MARK: - Video

    @ViewBuilder
    private var videoControls: some View {
        @Bindable var model = app.gameSettings

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("View distance")
                Spacer()
                Text("\(Int(viewDistanceDraft)) m")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $viewDistanceDraft,
                in: 500...12_000,
                step: 100,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    model.viewDistance = viewDistanceDraft
                    // Objects can never be drawn further than the terrain.
                    if objectDistanceDraft > viewDistanceDraft {
                        objectDistanceDraft = viewDistanceDraft
                        model.objectViewDistance = viewDistanceDraft
                    }
                    model.markDirty()
                }
            )
            .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Object distance")
                Spacer()
                Text("\(Int(objectDistanceDraft)) m")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $objectDistanceDraft,
                in: 300...12_000,
                step: 100,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    objectDistanceDraft = min(objectDistanceDraft, viewDistanceDraft)
                    model.objectViewDistance = objectDistanceDraft
                    model.markDirty()
                }
            )
            .labelsHidden()
        }

        Picker("Terrain detail", selection: $model.terrainQuality) {
            ForEach(GameSettingsModel.TerrainQuality.allCases) { quality in
                Text(quality.title).tag(quality)
            }
        }
        .onChange(of: model.terrainQuality) { _, _ in model.markDirty() }
    }

    // MARK: - Apply bar

    private var applyBar: some View {
        HStack(spacing: 10) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let status = model.status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
            } else {
                Text("Close Arma before applying — it rewrites its profile when it quits.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Reset FOV") {
                model.resetFOVToDefault()
                fovDraft = model.horizontalFOV
            }
            .disabled(model.isDefaultFOV)

            Button("Revert") {
                model.discardChanges()
                fovDraft = model.horizontalFOV
            }
            .disabled(model.selectedProfile == nil)

            Button("Apply to Arma") { model.apply() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedProfile == nil)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Profile actions

    private func present(_ sheet: ProfileSheet) {
        switch sheet {
        case .create:
            pendingName = ""
            copySource = nil
        case .duplicate:
            pendingName = suggestedCopyName(for: model.selectedProfile?.name ?? "Profile")
            copySource = model.selectedProfile
        case .rename:
            pendingName = model.selectedProfile?.name ?? ""
            copySource = nil
        }
        self.sheet = sheet
    }

    /// "Alpha" becomes "Alpha 2", then "Alpha 3", so duplicating twice never collides.
    private func suggestedCopyName(for name: String) -> String {
        var index = 2
        while !model.isNameAvailable("\(name) \(index)"), index < 50 { index += 1 }
        return "\(name) \(index)"
    }

    private var canConfirmName: Bool {
        let trimmed = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if sheet == .rename, trimmed == model.selectedProfile?.name { return false }
        return model.isNameAvailable(trimmed)
    }

    private func confirmName() {
        let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let installation = app.selectedInstallation

        switch sheet {
        case .create:
            model.createProfile(named: name, copying: copySource, installation: installation)
        case .duplicate:
            if let profile = model.selectedProfile {
                model.duplicateProfile(profile, named: name, installation: installation)
            }
        case .rename:
            if let profile = model.selectedProfile {
                let wasLaunchProfile = isLaunchProfile(profile)
                model.renameProfile(profile, to: name, installation: installation)
                // Keep -name= pointing at the profile the user just renamed.
                if wasLaunchProfile { app.settings.launchOptions.profileName = name }
            }
        case nil:
            break
        }
        sheet = nil
    }

    private func isLaunchProfile(_ profile: ArmaProfile) -> Bool {
        let configured = app.settings.launchOptions.profileName
        if let configured, !configured.isEmpty { return configured == profile.name }
        // With no -name=, Arma uses the default profile.
        return profile.isDefault
    }

    private func useForLaunch(_ profile: ArmaProfile) {
        app.settings.launchOptions.profileName = profile.isDefault ? nil : profile.name
    }

    @ViewBuilder
    private func nameSheet(_ sheet: ProfileSheet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sheet.title).font(.headline)

            TextField("Profile name", text: $pendingName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { if canConfirmName { confirmName() } }

            if sheet == .create, !model.profiles.isEmpty {
                Picker("Start from", selection: $copySource) {
                    Text("Empty profile").tag(ArmaProfile?.none)
                    ForEach(model.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile))
                    }
                }
                .frame(width: 300)
            }

            if !pendingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !canConfirmName {
                Label("That name is already taken.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { self.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(sheet.confirmTitle) { confirmName() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirmName)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
