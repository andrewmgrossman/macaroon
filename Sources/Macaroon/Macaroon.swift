import AppKit
import SwiftUI

final class MacaroonAppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appModel?.prepareForTermination()
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
                .task {
                    appDelegate.appModel = appModel
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandMenu("Navigate") {
                Button("Search Library") {
                    appModel.requestSearchFocus()
                }
                .keyboardShortcut("f", modifiers: [.command])

                Button("Back") {
                    appModel.goBack()
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Forward") {
                    appModel.goForward()
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(appModel.canGoForward == false)
            }

            CommandMenu("Playback") {
                Button("Play/Pause") {
                    appModel.transport(.playPause)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Previous") {
                    appModel.transport(.previous)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Next") {
                    appModel.transport(.next)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
            }

            CommandGroup(after: .toolbar) {
                Button(appModel.isQueueSidebarVisible ? "Hide Queue" : "Show Queue") {
                    appModel.toggleQueueSidebar()
                }
                .keyboardShortcut("q", modifiers: [.command, .option])

                Button("Dismiss") {
                    appModel.dismissTransientUI()
                }
                .keyboardShortcut(.escape, modifiers: [])
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
                .navigationTitle("Settings")
                .frame(width: 480, height: 190)
        }
    }
}
