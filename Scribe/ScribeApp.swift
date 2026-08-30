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
                    delegate.app = app
                    app.intelligence.refreshAvailability()
                    app.refreshInputDevices()
                    await app.loadLanguages()
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
                Button("Bookmark This Moment") { app.addBookmark() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(app.document?.isRecording != true)
            }
        }

        MenuBarExtra {
            MenuBarContent(app: app)
        } label: {
            Image(systemName: menuBarSymbol)
        }
    }

    private var menuBarSymbol: String {
        guard let document = app.document, document.isRecording else { return "waveform" }
        if document.isInterrupted { return "exclamationmark.triangle.fill" }
        return document.isPaused ? "pause.circle.fill" : "record.circle.fill"
    }
}

private struct MenuBarContent: View {
    @Bindable var app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let document = app.document, document.isRecording {
            Text("Recording · \(timecode(document.elapsed))")
            if document.isInterrupted {
                Button("Resume Recording") { Task { await document.resumeRecording() } }
            } else if document.isPaused {
                Button("Resume") { Task { await document.resumeRecording() } }
            } else {
                Button("Pause") { document.pauseRecording() }
                Button("Bookmark This Moment") { document.addBookmark() }
            }
            Button("Stop Recording") { Task { await document.stopRecording() } }
        } else if let document = app.document {
            Button("Start Recording") { Task { await document.startRecording() } }
        }

        Divider()
        Button("Open Scribe") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("New Session") { app.newSession() }
        Divider()
        Button("Quit Scribe") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Don't let ⌘Q / closing the window silently discard a running recording.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let document = app?.document, document.isRecording else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = "Scribe is still recording. Quitting stops the recording and saves what you have."
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await document.stopRecording()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
