import Foundation

/// Top-level state: the library folder, the on-device model, and the session on screen.
@MainActor
@Observable
final class AppModel {

    let library = Library()
    let intelligence = IntelligenceService()

    private(set) var document: SessionDocument?
    var showingSessions = false
    /// The hidden provider-settings panel — opened by Option-clicking the Sessions button.
    var showingSettings = false

    /// Locales this Mac can transcribe, loaded once on launch for the language picker.
    private(set) var languages: [Locale] = []

    func loadLanguages() async {
        languages = await SpeechLanguages.available()
    }

    /// Microphones available for the input picker; refreshed when the panel is idle.
    private(set) var inputDevices: [AudioInputDevice] = []

    func refreshInputDevices() {
        inputDevices = AudioDevices.inputs()
    }

    func addBookmark() { document?.addBookmark() }

    /// Called once the window appears. Always lands on a clean session to record into — the
    /// most recent transcript is one tap away in the Sessions list — but reuses a still-blank
    /// most-recent session instead of leaving another empty one behind.
    func bootstrap() {
        guard document == nil, !library.needsFolder else { return }
        document = launchSession()
    }

    private func launchSession() -> SessionDocument {
        guard let recent = library.sessions().first else { return freshDocument() }
        let mostRecent = SessionDocument(loaded: library.load(recent), library: library, intelligence: intelligence)
        return mostRecent.isBlank ? mostRecent : freshDocument()
    }

    func newSession() {
        if library.needsFolder {
            library.chooseFolder()
            guard !library.needsFolder else { return }
        }
        Task { [weak self] in
            guard let self else { return }
            if let current = self.document {
                // Already sitting on an untouched blank session — nothing to create.
                if current.isBlank { return }
                if current.isRecording { await current.stopRecording() }
            }
            self.document = self.freshDocument()
        }
    }

    func delete(_ ref: SessionRef) {
        if document?.meta.id == ref.meta.id, let doc = document {
            // Quiesce the on-screen session first — otherwise a pending autosave or a
            // still-running recording rewrites the folder right after it's trashed.
            Task { [weak self] in
                await doc.prepareForDeletion()
                self?.finishDelete(ref, wasCurrent: true)
            }
        } else {
            finishDelete(ref, wasCurrent: false)
        }
    }

    private func finishDelete(_ ref: SessionRef, wasCurrent: Bool) {
        library.deleteSession(ref)
        guard wasCurrent else { return }
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
        // `bootstrap()` now opens a fresh blank session; `--aitest` needs a real transcript,
        // so reopen the most recent saved session for that run.
        if args.contains("--aitest"), document?.isBlank == true, let recent = library.sessions().first {
            document = SessionDocument(loaded: library.load(recent), library: library, intelligence: intelligence)
        }
        try? await Task.sleep(for: .seconds(1))
        guard let document else { dbg("no document (needsFolder=\(library.needsFolder))"); return }

        if args.contains("--autorecord") {
            await document.startRecording()
            let seconds = (args.firstIndex(of: "--autorecord").map { $0 + 1 })
                .flatMap { $0 < args.count ? Double(args[$0]) : nil } ?? 12
            dbg("recording on '\(document.transcriber.inputDeviceName)' pref=\(document.transcriber.preferredInputUID ?? "auto")")
            var peakSeen: Float = 0
            for _ in 0..<Int(seconds) {
                try? await Task.sleep(for: .seconds(1))
                peakSeen = max(peakSeen, document.transcriber.meterLevels.max() ?? 0)
            }
            await document.stopRecording()
            document.saveNow()
            dbg("autorecord done: \(document.segments.count) segments, elapsed=\(Int(document.elapsed))s peakMeter=\(String(format: "%.3f", peakSeen)) phase=\(document.transcriber.phase)")
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
