import SwiftUI

@main
struct AirPlayDropApp: App {
    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open File…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        Settings {
            DependencySettingsView()
        }
    }
}

extension Notification.Name {
    static let openFileRequested = Notification.Name("AirPlayDrop.openFileRequested")
}
