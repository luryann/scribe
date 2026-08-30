import Foundation

/// Top-level state: the library folder, the on-device model, and the session on screen.
@MainActor
@Observable
final class AppModel {

    let library = Library()
    let intelligence = IntelligenceService()

    private(set) var document: SessionDocument?
    var showingSessions = false

    /// Called once the window appears. Reopens the most recent session, or starts a fresh one.
    func bootstrap() {
        guard document == nil, !library.needsFolder else { return }
        if let recent = library.sessions().first {
            document = SessionDocument(loaded: library.load(recent), library: library, intelligence: intelligence)
        } else {
            document = freshDocument()
        }
    }

    func newSession() {
        if library.needsFolder {
            library.chooseFolder()
            guard !library.needsFolder else { return }
        }
        Task { [weak self] in
            if let current = self?.document, current.isRecording {
                await current.stopRecording()
            }
            self?.document = self?.freshDocument()
        }
    }

    func delete(_ ref: SessionRef) {
        library.deleteSession(ref)
        guard document?.meta.id == ref.meta.id else { return }
        if let next = library.sessions().first {
            document = SessionDocument(loaded: library.load(next), library: library, intelligence: intelligence)
        } else {
            document = freshDocument()
        }
    }

    func open(_ ref: SessionRef) {
        Task { [weak self] in
            guard let self else { return }
            if let current = self.document, current.isRecording {
                await current.stopRecording()
            }
            self.document = SessionDocument(loaded: self.library.load(ref), library: self.library, intelligence: self.intelligence)
            self.showingSessions = false
        }
    }

    #if DEBUG
    private func dbg(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scribe-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    /// Supports `--autorecord [seconds]` and `--aitest` for headless smoke testing.
    func runDebugLaunchArguments() async {
        let args = CommandLine.arguments
        guard args.contains("--autorecord") || args.contains("--aitest") else { return }
        dbg("launch args: \(args.dropFirst().joined(separator: " "))")
        if library.needsFolder { library.useContainerFolderForTesting() }

        bootstrap()
        try? await Task.sleep(for: .seconds(1))
        guard let document else { dbg("no document (needsFolder=\(library.needsFolder))"); return }

        if args.contains("--autorecord") {
            await document.startRecording()
            let seconds = (args.firstIndex(of: "--autorecord").map { $0 + 1 })
                .flatMap { $0 < args.count ? Double(args[$0]) : nil } ?? 12
            try? await Task.sleep(for: .seconds(seconds))
            await document.stopRecording()
            document.saveNow()
            dbg("autorecord done: \(document.segments.count) segments, phase=\(document.transcriber.phase)")
        }

        if args.contains("--aitest") {
            guard document.hasTranscript else { dbg("aitest: no transcript"); return }
            dbg("aiAvailable=\(intelligence.isAvailable) reason=\(intelligence.unavailableReason ?? "-")")
            dbg("transcript: \(document.fullTranscript.prefix(160))")
            await document.summarize()
            dbg("SUMMARY:\n\(document.summary)")
            await document.generateFlashcards()
            dbg("CARDS: \(document.flashcards.count)")
            for c in document.flashcards.prefix(4) { dbg("  Q: \(c.front) | A: \(c.back)") }
            await document.generateTodos()
            dbg("TODOS: \(document.todos.count)")
            for t in document.todos { dbg("  - \(t.text) [due:\(t.dueHint ?? "-")] [t:\(t.sourceTime.map { String(format: "%.0f", $0) } ?? "-")]") }
            dbg("aiError: \(document.aiError ?? "none")")
        }
        dbg("debug run complete")
    }
    #endif

    private func freshDocument() -> SessionDocument {
        let meta = SessionMeta(
            title: SessionDocument.defaultTitle,
            createdAt: .now,
            updatedAt: .now,
            duration: 0,
            folderName: ""
        )
        return SessionDocument(meta: meta, store: nil, library: library, intelligence: intelligence)
    }
}
