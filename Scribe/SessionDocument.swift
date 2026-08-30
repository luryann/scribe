import Foundation
import FoundationModels

enum AIJob: Equatable {
    case summary, cards, todos, notes, title
}

/// One recording session and everything derived from it. Owns the transcriber, keeps the
/// live transcript, and autosaves to disk as things change.
@MainActor
@Observable
final class SessionDocument {

    static let defaultTitle = "New Session"

    var meta: SessionMeta
    var segments: [TranscriptSegment] = []
    /// Rebuilt incrementally as segments finalize — never a full recompute during recording.
    private(set) var paragraphs: [TranscriptParagraph] = []
    var volatile: String = ""
    var summary: String = ""
    var notes: String = ""
    var flashcards: [Flashcard] = []
    var todos: [TodoItem] = []
    var bookmarks: [Bookmark] = []

    var tab: MainTab = .live
    var elapsed: TimeInterval = 0
    var locale: Locale = SpeechLanguages.preferred

    /// Set by "jump to source" — LiveView scrolls to this paragraph and flashes it.
    var scrollTarget: TranscriptParagraph.ID?

    var runningJob: AIJob?
    var aiError: String?
    /// `(step, total)` while a multi-pass AI job runs over a long transcript.
    var jobProgress: (step: Int, total: Int)?

    /// Non-blocking heads-up messages shown in the footer (low battery, low disk, sleep gap…).
    var warnings: [String] = []
    @ObservationIgnored private var lastHealthCheck = Date.distantPast

    let transcriber = Transcriber()

    @ObservationIgnored private(set) var store: SessionStore?
    @ObservationIgnored private unowned let library: Library
    @ObservationIgnored private unowned let intelligence: IntelligenceService
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedAt = Date.distantPast
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var jobTask: Task<Void, Never>?

    /// Longest we let the debounced autosave be starved by continuous speech.
    private let maxSaveInterval: TimeInterval = 10

    var isRecording: Bool { transcriber.isActive }
    var isPaused: Bool { transcriber.isPaused }
    var isInterrupted: Bool { transcriber.isInterrupted }

    init(meta: SessionMeta, store: SessionStore?, library: Library, intelligence: IntelligenceService) {
        self.meta = meta
        self.store = store
        self.library = library
        self.intelligence = intelligence

        transcriber.onFinalSegment = { [weak self] text, start in
            guard let self else { return }
            let segment = TranscriptSegment(text: text, start: start)
            self.segments.append(segment)
            TranscriptLayout.append(segment, to: &self.paragraphs)
            self.volatile = ""
            self.scheduleSave()
        }
        transcriber.onVolatile = { [weak self] text in
            self?.volatile = text
        }
        transcriber.onInterrupted = { [weak self] in
            guard let self else { return }
            self.stopTicker()
            self.meta.duration = self.elapsed
            self.saveNow()
        }
        transcriber.onGap = { [weak self] seconds in
            guard let self else { return }
            let minutes = max(1, Int((seconds / 60).rounded()))
            self.bookmarks.append(Bookmark(time: self.elapsed, label: "Gap ~\(minutes) min (Mac asleep)"))
            self.bookmarks.sort { $0.time < $1.time }
            if !self.warnings.contains(where: { $0.hasPrefix("Recording paused") }) {
                self.warnings.append("Recording paused while the Mac slept — keep the lid open during a lecture.")
            }
            self.saveNow()
        }
        transcriber.onResumed = { [weak self] in
            // An automatic recovery restored the recording; `onInterrupted` stopped the
            // ticker, so bring it back or the timer and health checks stay frozen.
            self?.startTicker()
        }
    }

    convenience init(loaded: LoadedSession, library: Library, intelligence: IntelligenceService) {
        self.init(meta: loaded.meta, store: loaded.store, library: library, intelligence: intelligence)
        segments = loaded.segments
        paragraphs = TranscriptLayout.paragraphs(from: loaded.segments)
        summary = loaded.summary
        notes = loaded.notes
        flashcards = loaded.flashcards
        todos = loaded.todos
        bookmarks = loaded.bookmarks
        elapsed = loaded.meta.duration
    }

    var fullTranscript: String {
        segments.map(\.text).joined(separator: " ")
    }

    var hasTranscript: Bool { !segments.isEmpty }

    // MARK: Recording

    func toggleRecording() async {
        if transcriber.isActive {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        materializeIfNeeded()
        warnings = []
        runReadinessCheck()
        startTicker()
        await transcriber.start(locale: locale, startOffset: elapsed)
        if case .unavailable = transcriber.phase {
            stopTicker()
        }
    }

    /// One-shot pre-flight before a (possibly hours-long, unplugged) recording.
    private func runReadinessCheck() {
        lastHealthCheck = .now
        var notes: [String] = []

        if let capacity = library.availableCapacity(), capacity < 500_000_000 {
            notes.append("Under 500 MB free where Scribe saves — free up space before a long lecture.")
        }
        if !library.rootReachable() {
            notes.append("Can't reach your Scribe folder — is the drive still connected?")
        }
        let power = PowerMonitor.snapshot()
        if let percent = power.batteryPercent, !power.isPluggedIn, percent < 30 {
            notes.append("Battery at \(percent)% and unplugged — a 4-hour lecture won't fit. Plug in.")
        } else if power.lowPowerMode {
            notes.append("Low Power Mode is on — it can throttle transcription. Consider turning it off.")
        }
        warnings = notes
    }

    /// Runs every couple of minutes from the ticker while recording.
    private func runHealthCheck() {
        guard Date.now.timeIntervalSince(lastHealthCheck) > 120 else { return }
        lastHealthCheck = .now

        var notes = warnings.filter { $0.hasPrefix("Recording paused") }   // keep the sleep-gap note
        if let capacity = library.availableCapacity(), capacity < 300_000_000 {
            notes.append("Running low on disk space — the transcript may stop saving.")
        }
        let power = PowerMonitor.snapshot()
        if let percent = power.batteryPercent, !power.isPluggedIn, percent < 15 {
            notes.append("Battery at \(percent)% — plug in now or stop soon to be safe.")
        }
        warnings = notes
    }

    func stopRecording() async {
        await transcriber.stop()
        stopTicker()
        meta.duration = elapsed
        saveNow()

        if meta.title == Self.defaultTitle, fullTranscript.count > 60 {
            Task { await autoTitle() }
        }
    }

    func pauseRecording() {
        transcriber.pause()
    }

    func resumeRecording() async {
        if transcriber.isInterrupted {
            startTicker()
            await transcriber.resumeFromInterruption()
        } else {
            await transcriber.resume()
        }
    }

    // MARK: Bookmarks

    func addBookmark() {
        bookmarks.append(Bookmark(time: elapsed))
        bookmarks.sort { $0.time < $1.time }
        scheduleSave()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        scheduleSave()
    }

    // MARK: AI actions

    var isRunningJob: Bool { runningJob != nil }

    func cancelJob() {
        jobTask?.cancel()
    }

    func summarize() async {
        await runJob(.summary) {
            self.summary = try await self.intelligence.summarize(self.fullTranscript, onProgress: self.report)
        }
    }

    func generateFlashcards() async {
        await runJob(.cards) {
            self.flashcards = try await self.intelligence.flashcards(from: self.fullTranscript, onProgress: self.report)
        }
    }

    func generateTodos() async {
        await runJob(.todos) {
            let generated = try await self.intelligence.todos(from: self.fullTranscript, onProgress: self.report)
            self.todos = generated.map { task in
                TodoItem(
                    text: task.task,
                    dueHint: task.due.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : task.due,
                    sourceQuote: task.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : task.source,
                    sourceTime: TranscriptMatcher.time(for: task.source, in: self.segments)
                )
            }
        }
    }

    func polishNotes() async { await runJob(.notes) { self.notes = try await self.intelligence.polishedNotes(self.notes) } }

    private func report(_ step: Int, _ total: Int) {
        jobProgress = total > 1 ? (step, total) : nil
    }

    private func autoTitle() async {
        guard let suggestion = try? await intelligence.suggestedTitle(from: fullTranscript),
              !suggestion.isEmpty else { return }
        meta.title = suggestion
        scheduleSave()
    }

    private func runJob(_ job: AIJob, _ work: @escaping () async throws -> Void) async {
        guard intelligence.isAvailable else {
            aiError = intelligence.unavailableReason
            return
        }
        jobTask?.cancel()
        // Claim the slot synchronously so the footer button disables before a fast second
        // tap can spawn a rival job.
        runningJob = job
        jobProgress = nil
        aiError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work()
                try Task.checkCancellation()
                self.scheduleSave()
            } catch is CancellationError {
                // user cancelled / superseded — leave prior output untouched
            } catch {
                self.aiError = Self.aiMessage(for: error)
            }
        }
        jobTask = task
        await task.value
        // Only clear if a newer job hasn't taken over in the meantime — otherwise a
        // superseded job's teardown would wipe the live one's state.
        if jobTask == task {
            runningJob = nil
            jobProgress = nil
            jobTask = nil
        }
    }

    private static func aiMessage(for error: any Error) -> String {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return "This lecture is very long — try Summarize first, then generate from the summary."
            case .guardrailViolation, .refusal:
                return "Apple's model declined this transcript. Try again, or edit the text first."
            case .rateLimited, .concurrentRequests:
                return "The model is busy. Wait a moment and try again."
            case .assetsUnavailable:
                return "Apple Intelligence isn't ready yet. Try again shortly."
            default:
                return "That didn't work: \(generation.localizedDescription)"
            }
        }
        return "That didn't work: \(error.localizedDescription)"
    }

    // MARK: To-dos

    func addTodo(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.append(TodoItem(text: trimmed))
        scheduleSave()
    }

    func jump(to time: TimeInterval) {
        tab = .live
        let target = paragraphs.last { $0.start <= time + 0.25 } ?? paragraphs.first
        scrollTarget = target?.id
    }

    // MARK: Persistence

    func materializeIfNeeded() {
        guard store == nil else { return }
        guard let created = try? library.makeSession(title: meta.title) else { return }
        store = created
        meta.folderName = created.folder.lastPathComponent
    }

    func scheduleSave() {
        // Hard floor: never let continuous speech starve the autosave past `maxSaveInterval`.
        if Date.now.timeIntervalSince(lastSavedAt) > maxSaveInterval {
            saveNow()
            return
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        if store == nil, (hasTranscript || !notes.isEmpty || !bookmarks.isEmpty) { materializeIfNeeded() }
        guard let store else { return }
        saveTask?.cancel()
        lastSavedAt = .now
        meta.updatedAt = .now
        if transcriber.isActive { meta.duration = elapsed }
        library.save(
            SessionSnapshot(
                meta: meta,
                store: store,
                segments: segments,
                summary: summary,
                notes: notes,
                flashcards: flashcards,
                todos: todos,
                bookmarks: bookmarks
            )
        )
    }

    /// Called right before this session's folder is moved to the Trash: stop everything that
    /// could still write to disk, so a late autosave can't recreate the deleted folder.
    func prepareForDeletion() async {
        jobTask?.cancel()
        stopTicker()
        if transcriber.isActive { await transcriber.stop() }
        // `stop()` can flush a final segment and schedule one more save on its way out —
        // cancel that too, after the drain.
        saveTask?.cancel()
        saveTask = nil
    }

    // MARK: Timer

    /// Wall-clock accumulation: advance `elapsed` by the real time between ticks while the
    /// transcriber is actually running, clamped so a long suspension (Mac asleep) can't add a
    /// huge jump. Frozen while paused. Segment timestamps come from the analyzer, not this.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            var last = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let now = Date.now
                let delta = now.timeIntervalSince(last)
                last = now
                guard let self else { return }
                guard self.transcriber.isRunning else { continue }
                self.elapsed += min(delta, 2)
                self.meta.duration = self.elapsed
                self.runHealthCheck()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
