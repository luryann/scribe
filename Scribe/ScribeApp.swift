import AppKit
import SwiftUI

@main
struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Scribe", id: "main") {
            RootView()
                .environment(app)
                .background(WindowConfigurator())
                .task {
                    app.intelligence.refreshAvailability()
                    #if DEBUG
                    await app.runDebugLaunchArguments()
                    #endif
                }
        }
        .defaultSize(width: 360, height: 468)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { app.newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Sessions") { app.showingSessions.toggle() }
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
