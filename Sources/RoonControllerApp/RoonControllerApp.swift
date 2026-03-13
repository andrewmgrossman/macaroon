import AppKit
import SwiftUI

@main
struct RoonControllerApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Macaroon") {
            RootView()
                .environment(appModel)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandMenu("Server") {
                Button("Reconnect") {
                    appModel.connectAutomatically()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Disconnect") {
                    appModel.disconnect()
                }
                .disabled(appModel.connectionStatus == .disconnected)

                Divider()

                Button("Server Settings…") {
                    appModel.openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Macaroon") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(appModel)
                .frame(width: 480, height: 260)
        }
    }
}
