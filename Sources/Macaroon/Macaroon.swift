import AppKit
import SwiftUI

final class MacaroonAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png", subdirectory: "Resources"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct Macaroon: App {
    @NSApplicationDelegateAdaptor(MacaroonAppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appModel.openSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

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
