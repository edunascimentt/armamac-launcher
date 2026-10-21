import SwiftUI

/// The PARAMETERS section: the startup switches, with the command line they add up to
/// pinned along the bottom the way the launcher shows it.
struct ParametersView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ParametersSettingsTab()
            Divider()
            commandLine
        }
    }

    private var commandLine: some View {
        HStack(spacing: 8) {
            Text(app.previewPlan()?.displayCommand ?? "No Arma 3 installation selected")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button("Copy") {
                guard let plan = app.previewPlan() else { return }
                app.copyToPasteboard(plan.displayCommand)
            }
            .controlSize(.small)
            .disabled(app.previewPlan() == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
