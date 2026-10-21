import SwiftUI

@main
struct ArmaMacApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("ArmaMac", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 720, minHeight: 480)
                .task { await app.bootstrap() }
        }
        .defaultSize(width: 1_060, height: 700)
        .commands { LauncherCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
