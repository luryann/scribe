import Foundation
import FoundationModels

/// Errors surfaced to the user by name (see `SessionDocument.aiMessage(for:)`).
enum IntelligenceError: LocalizedError {
    case notesTidyLostContent

    var errorDescription: String? {
        switch self {
        case .notesTidyLostContent:
            return "Couldn't tidy those notes without dropping content, so nothing was changed."
        }
    }
}

/// The on-device backend: everything Scribe asks Apple's `FoundationModels` to do. No
/// network, no accounts. Apple's model has a fixed 4096-token context, so every pass here is
/// planned around it — the transcript is chunked to a measured budget and long results are
/// folded, never prefix-truncated. See CLAUDE.md "On-device AI context budget".
@MainActor
@Observable
final class AppleIntelligenceBackend: IntelligenceBackend {

    private(set) var isAvailable = false
    private(set) var unavailableReason: String?

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            isAvailable = true
            unavailableReason = nil
        case .unavailable(let reason):
            isAvailable = false
            switch reason {
            case .deviceNotEligible:
                unavailableReason = "This Mac doesn't support Apple Intelligence, so Scribe's AI features are off."
            case .appleIntelligenceNotEnabled:
                unavailableReason = "Turn on Apple Intelligence in System Settings to use Scribe's AI features."
            case .modelNotReady:
                unavailableReason = "Apple Intelligence is still downloading its model. Try again shortly."
            @unknown default:
                unavailableReason = "Scribe's AI features aren't available right now."
            }
        }
    }

    /// Characters of transcript/notes text that safely fit in one prompt for a given pass,
    /// once the pass's instructions and its response are accounted for against the model's
    /// context window (4096 tokens today). On macOS 26.4+ the instruction cost is measured
    /// exactly; otherwise a conservative estimate is used. `shrink` (< 1) tightens every
    /// budget for a retry after an overflow.
    private func charBudget(
        for instructions: Instructions,
        reservingOutput output: Int,
        shrink: Double = 1
    ) async -> Int {
        let context = SystemLanguageModel.default.contextSize
        var instructionTokens = 380   // conservative default: our longest instruction block
        if #available(macOS 26.4, *) {
            if let measured = try? await SystemLanguageModel.default.tokenCount(for: instructions) {
                instructionTokens = measured
            }
        }
        let overhead = 200            // chat template + delimiters + "Part X of Y" scaffold
        let inputTokens = max(256, context - instructionTokens - output - overhead)
        // ~3 chars/token — deliberately below the ~4 English prose actually runs, as headroom.
        return max(600, Int(Double(inputTokens) * 3 * shrink))
    }

    /// Token allowances used to reserve output space in `charBudget`. `note`/`fold`/`summary`
    /// are also passed as `maximumResponseTokens` on their (free-text) calls, where hitting the
    /// cap just ends the text early. `deck`/`taskList` are reservations only — a hard cap on a
    /// guided-generation call can truncate the JSON mid-structure and fail the whole decode, so
    /// those calls stay uncapped and these numbers are set high enough to cover a full result.
    private enum Out {
        static let note = 220, fold = 260, summary = 420
        static let deck = 1100        // reservation: ~14 cards + the schema echoed into the prompt
        static let taskList = 1200    // reservation: up to 12 tasks, each with a quoted source sentence
    }

    // MARK: Summary

    func summarize(_ transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        return try await runSummary(clean, onProgress: onProgress, shrink: 1)
    }

    /// Map-reduce summary. Every model call is kept inside the context window: the transcript
    /// is chunked to a measured budget, each chunk becomes fact notes, and the notes are
    /// folded pairwise in rounds until they fit a single merge call. If a call still overflows
    /// (a bad char/token estimate on unusual text), the whole pass retries with a tighter budget.
    private func runSummary(_ clean: String, onProgress: ((Int, Int) -> Void)?, shrink: Double) async throws -> String {
        do {
            let soloTarget = Self.bulletTarget(chunks: 1)
            let soloBudget = await charBudget(for: Self.summaryInstructions(bulletTarget: soloTarget), reservingOutput: Out.summary, shrink: shrink)
            if clean.count <= soloBudget {
                let session = LanguageModelSession(instructions: Self.summaryInstructions(bulletTarget: soloTarget))
                session.prewarm()
                return try await session.respond(
                    to: "Summarize this session.\n\n\(Prompts.wrap(clean))",
                    options: GenerationOptions(maximumResponseTokens: Out.summary)
                ).content
            }

            let noteBudget = await charBudget(for: Self.chunkNoteInstructions, reservingOutput: Out.note, shrink: shrink)
            let chunks = TranscriptChunker.chunks(clean, maxCharacters: noteBudget)
            var partials: [String] = []
            var total = chunks.count + 2   // notes + (at least) one merge; grows if folding is needed
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                onProgress?(index + 1, total)
                let session = LanguageModelSession(instructions: Self.chunkNoteInstructions)
                session.prewarm()
                partials.append(try await session.respond(
                    to: "Part \(index + 1) of \(chunks.count).\n\n\(Prompts.wrap(chunk))",
                    options: GenerationOptions(maximumResponseTokens: Out.note)
                ).content)
            }

            let mergeTarget = Self.bulletTarget(chunks: chunks.count)
            let foldBudget = await charBudget(for: Self.foldInstructions, reservingOutput: Out.fold, shrink: shrink)
            let mergeBudget = await charBudget(for: Self.mergeInstructions(bulletTarget: mergeTarget), reservingOutput: Out.summary, shrink: shrink)
            return try await reduce(partials, bulletTarget: mergeTarget, foldBudget: foldBudget, mergeBudget: mergeBudget) { step in
                total = max(total, chunks.count + step + 1)
                onProgress?(chunks.count + step, total)   // never reaches `total`, so never shows as done
            }
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error, shrink > 0.35 {
                return try await runSummary(clean, onProgress: onProgress, shrink: shrink * 0.6)
            }
            throw error
        }
    }

    /// Folds fact-note blocks pairwise in rounds until their concatenation fits `budget`
    /// characters (or nothing more can be merged). Keeps the output as "- " bullet lines, so
    /// definitions and numbers survive — no prose compression. `onStep` fires once per fold call.
    private func foldNotes(_ notes: [String], budget: Int, onStep: (Int) -> Void = { _ in }) async throws -> [String] {
        var work = notes
        var step = 0
        while work.joined(separator: "\n\n").count > budget, work.count >= 2 {
            var folded: [String] = []
            var index = 0
            while index < work.count {
                try Task.checkCancellation()
                step += 1
                onStep(step)
                let group = work[index..<min(index + 2, work.count)].joined(separator: "\n")
                let session = LanguageModelSession(instructions: Self.foldInstructions)
                folded.append(try await session.respond(
                    to: "Combine these notes.\n\n\(Prompts.wrap(String(group.prefix(budget)), tag: "NOTES"))",
                    options: GenerationOptions(maximumResponseTokens: Out.fold)
                ).content)
                index += 2
            }
            if folded.count >= work.count { break }   // defensive: never loop without shrinking
            work = folded
        }
        return work
    }

    /// Merges per-part notes into one summary, folding them down first when they don't fit a
    /// single merge call. `onStep` is called with 1, 2, 3… for each model call (folds, then merge).
    private func reduce(
        _ partials: [String],
        bulletTarget: String,
        foldBudget: Int,
        mergeBudget: Int,
        onStep: (Int) -> Void
    ) async throws -> String {
        var step = 0
        let folded = try await foldNotes(partials, budget: foldBudget) { _ in
            step += 1
            onStep(step)
        }

        try Task.checkCancellation()
        step += 1
        onStep(step)
        let joined = String(folded.joined(separator: "\n\n").prefix(mergeBudget))
        let session = LanguageModelSession(instructions: Self.mergeInstructions(bulletTarget: bulletTarget))
        session.prewarm()
        return try await session.respond(
            to: "Notes from consecutive parts of one lecture, in order.\n\n\(Prompts.wrap(joined, tag: "NOTES"))",
            options: GenerationOptions(maximumResponseTokens: Out.summary)
        ).content
    }

    // MARK: Flashcards

    func flashcards(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [Flashcard] {
        let source = try await condensedSource(from: transcript, onProgress: onProgress)
        guard !source.isEmpty else { return [] }

        try Task.checkCancellation()
        let session = LanguageModelSession(instructions: Self.flashcardInstructions)
        session.prewarm()
        let deck = try await session.respond(
            to: "Write flashcards from this material, covering its most important ideas, definitions and relationships in the order they appear. Write only as many as the material genuinely supports.\n\n\(Prompts.wrap(source, tag: "MATERIAL"))",
            generating: GeneratedDeck.self,
            options: GenerationOptions(sampling: .greedy)
        ).content

        return deck.cards
            .map { Flashcard(front: $0.front.trimmed, back: $0.back.trimmed) }
            .filter { !$0.front.isEmpty && !$0.back.isEmpty }
    }

    // MARK: To-dos

    func todos(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [ExtractedTask] {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        let chunkBudget = await charBudget(for: Self.todoInstructions, reservingOutput: Out.taskList)
        let chunks = TranscriptChunker.chunks(clean, maxCharacters: chunkBudget)
        var collected: [GeneratedTask] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, chunks.count)
            let session = LanguageModelSession(instructions: Self.todoInstructions)
            session.prewarm()
            let list = try await session.respond(
                to: "Part \(index + 1) of \(chunks.count) of one lecture.\n\n\(Prompts.wrap(chunk))",
                generating: GeneratedTaskList.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
            collected.append(contentsOf: list.tasks)
        }

        // Drop near-duplicate tasks that recur across chunks. Tasks with two or more content
        // words (chapter/set numbers kept — they're the usual discriminator) are compared as
        // sets: an equal or more-specific match already kept means skip; a strictly
        // more-specific incoming task replaces the broader one it covers, since the longer
        // phrasing tends to carry the due date. Thinner tasks fall back to exact-text matching.
        var result: [(words: Set<String>, task: GeneratedTask)] = []
        for task in collected {
            let text = task.task.trimmed
            guard text.count > 3 else { continue }
            let words = Self.contentWords(text)

            if words.count < 2 {
                let norm = text.lowercased()
                if !result.contains(where: { $0.task.task.trimmed.lowercased() == norm }) {
                    result.append((words, task))
                }
                continue
            }
            if result.contains(where: { $0.words == words || words.isSubset(of: $0.words) }) { continue }
            if let broader = result.firstIndex(where: { $0.words.isSubset(of: words) }) {
                result[broader] = (words, task)
                continue
            }
            result.append((words, task))
        }
        return result.map { ExtractedTask(task: $0.task.task, source: $0.task.source, due: $0.task.due) }
    }

    // MARK: Title & notes

    func suggestedTitle(from transcript: String) async throws -> String {
        let sample = Self.titleSample(from: transcript)
        guard sample.count > 40 else { return "" }

        let session = LanguageModelSession(instructions: Self.titleInstructions)
        let raw = try await session.respond(
            to: "Excerpt from a recording:\n\n\(Prompts.wrap(sample))",
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
        ).content

        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'."))
        // A well-behaved reply is a few words; anything longer is chatter we shouldn't save.
        guard (1...8).contains(cleaned.split(separator: " ").count) else { return "" }
        return cleaned
    }

    func polishedNotes(_ notes: String) async throws -> String {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 20 else { return notes }

        let session = LanguageModelSession(instructions: Self.notesInstructions)
        let tidied = try await session.respond(to: "Tidy these notes:\n\n\(Prompts.wrap(clean, tag: "NOTES"))")
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The result overwrites the student's own writing with no undo, so reject any pass that
        // came back suspiciously short — a small model's main failure here is silent condensing.
        guard !tidied.isEmpty, tidied.count >= (clean.count * 3) / 5 else {
            throw IntelligenceError.notesTidyLostContent
        }
        return tidied
    }

    // MARK: Helpers

    /// For flashcards, work from the transcript directly when it fits; otherwise from dense
    /// per-part fact notes (no lossy prose reduce — definitions and numbers have to survive).
    private func condensedSource(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // The deck call has to hold the source text *and* echo the schema, so its input budget
        // is what decides whether we can skip the note pass.
        let deckBudget = await charBudget(for: Self.flashcardInstructions, reservingOutput: Out.deck)
        if clean.count <= deckBudget { return clean }

        let noteBudget = await charBudget(for: Self.chunkNoteInstructions, reservingOutput: Out.note)
        let chunks = TranscriptChunker.chunks(clean, maxCharacters: noteBudget)
        var total = chunks.count + 1   // notes + the deck call; grows if the notes need folding
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, total)
            let session = LanguageModelSession(instructions: Self.chunkNoteInstructions)
            session.prewarm()
            notes.append(try await session.respond(
                to: "Part \(index + 1) of \(chunks.count).\n\n\(Prompts.wrap(chunk))",
                options: GenerationOptions(maximumResponseTokens: Out.note)
            ).content)
        }

        // A very long lecture produces more notes than the deck call can hold. Fold them down
        // in rounds (keeping every distinct fact) rather than truncating to the first half.
        let folded = try await foldNotes(notes, budget: deckBudget) { step in
            total = max(total, chunks.count + step + 1)
            onProgress?(chunks.count + step, total)
        }
        return String(folded.joined(separator: "\n").prefix(deckBudget))
    }

    /// 3–6 bullets for a short session, scaling up so a long lecture isn't crushed to six lines.
    private static func bulletTarget(chunks: Int) -> String {
        chunks <= 1 ? "3 to 6" : "\(min(6, 3 + chunks / 3)) to \(min(10, 5 + chunks))"
    }

    /// Lowercased content words for dedup keys: 3+ chars or a bare number (chapter/set/lab
    /// numbers are the usual thing that tells two otherwise-identical tasks apart), no stopwords.
    private static func contentWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !dedupeStopwords.contains($0) && ($0.count >= 3 || $0.allSatisfy(\.isNumber)) }
        )
    }

    private static let dedupeStopwords: Set<String> = [
        "the", "and", "for", "with", "your", "you", "this", "that", "from", "our", "are", "was"
    ]

    /// Skips the mic-check preamble: a little from the opening, more from the first third.
    private static func titleSample(from transcript: String) -> String {
        guard transcript.count > 2400 else { return String(transcript.prefix(1500)) }
        let head = String(transcript.prefix(600))
        let midStart = transcript.index(transcript.startIndex, offsetBy: transcript.count / 3)
        let mid = String(transcript[midStart...].prefix(900))
        return head + "\n…\n" + mid
    }

    // MARK: Instructions

    private static func summaryInstructions(bulletTarget: String) -> Instructions {
        Instructions(Prompts.summary(bulletTarget: bulletTarget))
    }
    private static let chunkNoteInstructions = Instructions(Prompts.chunkNote)
    private static let foldInstructions = Instructions(Prompts.fold)
    private static func mergeInstructions(bulletTarget: String) -> Instructions {
        Instructions(Prompts.merge(bulletTarget: bulletTarget))
    }
    private static let flashcardInstructions = Instructions(Prompts.flashcards)
    private static let todoInstructions = Instructions(Prompts.todos)
    private static let titleInstructions = Instructions(Prompts.title)
    private static let notesInstructions = Instructions(Prompts.notes)
}

// MARK: - Generable schemas (Apple-only)

@Generable
struct GeneratedDeck {
    @Guide(description: "Flashcards covering the key ideas in the order they came up; write only as many as the material genuinely supports", .count(3...14))
    var cards: [GeneratedCard]
}

@Generable
struct GeneratedCard {
    @Guide(description: "A clear question a student should be able to answer after studying")
    var front: String
    @Guide(description: "The correct answer, one or two sentences, self-contained")
    var back: String
}

@Generable
struct GeneratedTaskList {
    @Guide(description: "Every concrete action the student must take, in the order stated; empty if there are none", .maximumCount(12))
    var tasks: [GeneratedTask]
}

@Generable
struct GeneratedTask {
    @Guide(description: "The sentence from the transcript above that assigns this task, copied word for word — same words, same order, no paraphrase. Copy the whole sentence, not a fragment.")
    var source: String
    @Guide(description: "What the student has to do, taken from that sentence, as a short imperative of at most 12 words, e.g. \"Read chapter 4\"")
    var task: String
    @Guide(description: "A due-date hint only if the speaker stated one, e.g. \"Due Thursday\"; omit entirely when no deadline was stated")
    var due: String?
}

// MARK: - Chunking

enum TranscriptChunker {
    /// Splits long text on sentence boundaries into chunks no larger than `maxCharacters`.
    static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed.isEmpty ? [] : [trimmed] }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(in: trimmed.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        if sentences.isEmpty { sentences = [trimmed] }

        var result: [String] = []
        var current = ""
        var currentCount = 0   // track length as an Int; `String.count` in the loop is O(n) each call
        for sentence in sentences {
            // ASR output is often unpunctuated, so `.bySentences` can hand back one enormous
            // "sentence". Break it on word boundaries so no chunk ever exceeds the budget and
            // overflows the model's context window.
            guard sentence.count <= maxCharacters else {
                if !current.isEmpty { result.append(current); current = ""; currentCount = 0 }
                result.append(contentsOf: hardSplit(sentence, maxCharacters: maxCharacters))
                continue
            }
            let addition = sentence.count + (current.isEmpty ? 0 : 1)
            if currentCount + addition > maxCharacters, !current.isEmpty {
                result.append(current)
                current = ""
                currentCount = 0
            }
            if current.isEmpty {
                current = sentence
                currentCount = sentence.count
            } else {
                current += " " + sentence
                currentCount += addition
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Splits an over-long run of text on word boundaries (then, only if a single token is
    /// itself larger than the budget, on character count) so every piece fits `maxCharacters`.
    private static func hardSplit(_ text: String, maxCharacters: Int) -> [String] {
        guard maxCharacters > 0 else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count > maxCharacters {
                pieces.append(current)
                current = String(word)
            } else {
                current += " " + word
            }
        }
        if !current.isEmpty { pieces.append(current) }

        return pieces.flatMap { piece -> [String] in
            guard piece.count > maxCharacters else { return [piece] }
            var chopped: [String] = []
            var idx = piece.startIndex
            while idx < piece.endIndex {
                let end = piece.index(idx, offsetBy: maxCharacters, limitedBy: piece.endIndex) ?? piece.endIndex
                chopped.append(String(piece[idx..<end]))
                idx = end
            }
            return chopped
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
