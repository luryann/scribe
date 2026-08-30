import Foundation

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
    var volatile: String = ""
    var summary: String = ""
    var notes: String = ""
    var flashcards: [Flashcard] = []
    var todos: [TodoItem] = []

    var tab: MainTab = .live
    var elapsed: TimeInterval = 0
    var locale: Locale = SpeechLanguages.preferred

    /// Set by "jump to source" — LiveView scrolls to this segment and flashes it.
    var scrollTarget: TranscriptSegment.ID?

    var runningJob: AIJob?
    var aiError: String?

    let transcriber = Transcriber()

    @ObservationIgnored private(set) var store: SessionStore?
    @ObservationIgnored private unowned let library: Library
    @ObservationIgnored private unowned let intelligence: IntelligenceService
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var startDate: Date?

    var isRecording: Bool { transcriber.isRunning || transcriber.phase == .preparingModel || transcriber.phase == .requestingPermission }

    init(meta: SessionMeta, store: SessionStore?, library: Library, intelligence: IntelligenceService) {
        self.meta = meta
        self.store = store
        self.library = library
        self.intelligence = intelligence

        transcriber.onFinalSegment = { [weak self] text, start in
            guard let self else { return }
            self.segments.append(TranscriptSegment(text: text, start: start))
            self.volatile = ""
            self.scheduleSave()
        }
        transcriber.onVolatile = { [weak self] text in
            self?.volatile = text
        }
    }

    convenience init(loaded: LoadedSession, library: Library, intelligence: IntelligenceService) {
        self.init(meta: loaded.meta, store: loaded.store, library: library, intelligence: intelligence)
        segments = loaded.segments
        summary = loaded.summary
        notes = loaded.notes
        flashcards = loaded.flashcards
        todos = loaded.todos
        elapsed = loaded.meta.duration
    }

    var fullTranscript: String {
        segments.map(\.text).joined(separator: " ")
    }

    var hasTranscript: Bool { !segments.isEmpty }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        materializeIfNeeded()
        startTicker()
        await transcriber.start(locale: locale)
        if case .unavailable = transcriber.phase {
            stopTicker()
        }
    }

    func stopRecording() async {
        await transcriber.stop()
        stopTicker()
        meta.duration = elapsed
        scheduleSave()

        if meta.title == Self.defaultTitle, fullTranscript.count > 60 {
            Task { await autoTitle() }
        }
    }

    // MARK: AI actions

    func summarize() async { await run(.summary) { self.summary = try await self.intelligence.summarize(self.fullTranscript) } }

    func generateFlashcards() async { await run(.cards) { self.flashcards = try await self.intelligence.flashcards(from: self.fullTranscript) } }

    func generateTodos() async {
        await run(.todos) {
            let generated = try await self.intelligence.todos(from: self.fullTranscript)
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

    func polishNotes() async { await run(.notes) { self.notes = try await self.intelligence.polishedNotes(self.notes) } }

    private func autoTitle() async {
        guard let suggestion = try? await intelligence.suggestedTitle(from: fullTranscript),
              !suggestion.isEmpty else { return }
        meta.title = suggestion
        scheduleSave()
    }

    private func run(_ job: AIJob, _ work: @escaping () async throws -> Void) async {
        guard intelligence.isAvailable else {
            aiError = intelligence.unavailableReason
            return
        }
        runningJob = job
        aiError = nil
        do {
            try await work()
            scheduleSave()
        } catch {
            let description = error.localizedDescription
            if description.localizedCaseInsensitiveContains("unsafe")
                || description.localizedCaseInsensitiveContains("guardrail")
                || description.localizedCaseInsensitiveContains("safety") {
                aiError = "Apple's model declined this transcript. Try again, or edit the text first."
            } else if description.localizedCaseInsensitiveContains("context") {
                aiError = "This lecture is long — Scribe will summarize it in passes. Try again."
            } else {
                aiError = "That didn't work: \(description)"
            }
        }
        runningJob = nil
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
        let target = segments.last { $0.start <= time + 0.25 } ?? segments.first
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
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        if store == nil, (hasTranscript || !notes.isEmpty) { materializeIfNeeded() }
        guard let store else { return }
        meta.updatedAt = .now
        library.write(
            meta: meta,
            store: store,
            segments: segments,
            summary: summary,
            notes: notes,
            flashcards: flashcards,
            todos: todos
        )
    }

    // MARK: Timer

    private func startTicker() {
        startDate = Date.now.addingTimeInterval(-elapsed)
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let start = self.startDate else { break }
                self.elapsed = Date.now.timeIntervalSince(start)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        if let start = startDate { elapsed = Date.now.timeIntervalSince(start) }
    }
}
