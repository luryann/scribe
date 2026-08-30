import Foundation
import FoundationModels

/// Everything Scribe asks Apple's on-device model to do: summaries, flashcards, to-dos,
/// session titles, and note tidying. No network, no accounts.
@MainActor
@Observable
final class IntelligenceService {

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

    private var contextBudget: Int {
        max(1200, SystemLanguageModel.default.contextSize - 900)
    }

    // MARK: Summary

    func summarize(_ transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }

        let chunks = TranscriptChunker.chunks(clean, maxCharacters: contextBudget * 3)
        if chunks.count == 1 {
            let session = LanguageModelSession(instructions: Self.summaryInstructions)
            session.prewarm()
            return try await session.respond(
                to: "Summarize this lecture or discussion transcript. Start with a two or three sentence overview, then a \"Key points\" list of 3–6 bullets.\n\nTRANSCRIPT:\n\(clean)"
            ).content
        }

        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, chunks.count + 1)
            let session = LanguageModelSession(instructions: Self.summaryInstructions)
            let piece = try await session.respond(
                to: "This is part \(index + 1) of \(chunks.count) of a longer transcript. In 3–5 sentences, capture what matters in this part only.\n\n\(chunk)"
            ).content
            partials.append(piece)
        }

        try Task.checkCancellation()
        onProgress?(chunks.count + 1, chunks.count + 1)
        let session = LanguageModelSession(instructions: Self.summaryInstructions)
        return try await session.respond(
            to: "These are notes from consecutive parts of one lecture. Merge them into a single clean summary: a short overview paragraph, then a \"Key points\" list of 3–6 bullets. Remove repetition.\n\n\(partials.joined(separator: "\n\n"))"
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
            to: "Write study flashcards from this material. Cover the most important ideas, definitions and relationships in the order they appear.\n\n\(source)",
            generating: GeneratedDeck.self
        ).content

        return deck.cards
            .map { Flashcard(front: $0.front.trimmed, back: $0.back.trimmed) }
            .filter { !$0.front.isEmpty && !$0.back.isEmpty }
    }

    // MARK: To-dos

    func todos(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [GeneratedTask] {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        let chunks = TranscriptChunker.chunks(clean, maxCharacters: contextBudget * 3)
        var collected: [GeneratedTask] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onProgress?(index + 1, chunks.count)
            let session = LanguageModelSession(instructions: Self.todoInstructions)
            let list = try await session.respond(
                to: "Pull out every concrete action a student should take based on what the speaker said: readings, assignments, things to prepare, people to contact, deadlines. Ignore general advice. If nothing qualifies, return an empty list.\n\nTRANSCRIPT:\n\(chunk)",
                generating: GeneratedTaskList.self
            ).content
            collected.append(contentsOf: list.tasks)
        }

        // De-duplicate near-identical tasks that can appear across chunks.
        var seen = Set<String>()
        return collected.filter { task in
            let key = task.task.lowercased().trimmed
            guard key.count > 3, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    // MARK: Title & notes

    func suggestedTitle(from transcript: String) async throws -> String {
        let snippet = String(transcript.prefix(1500))
        guard snippet.count > 40 else { return "" }
        let session = LanguageModelSession(instructions: "You name lecture recordings. Reply with a title of 3–6 words, no quotes, no trailing punctuation.")
        return try await session.respond(to: "Give this recording a short, specific title:\n\n\(snippet)")
            .content
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'."))
    }

    func polishedNotes(_ notes: String) async throws -> String {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 20 else { return notes }
        let session = LanguageModelSession(instructions: "You tidy a student's rough notes. Fix grammar and spelling, tighten phrasing, and organize into short paragraphs or bullet points. Never add facts that aren't already there. Keep the student's meaning and voice.")
        return try await session.respond(to: "Tidy these notes:\n\n\(clean)").content
    }

    // MARK: Helpers

    /// For flashcards, work from the transcript directly when it fits, otherwise from a summary of it.
    private func condensedSource(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= contextBudget * 3 { return clean }
        return try await summarize(clean, onProgress: onProgress)
    }

    private static let summaryInstructions = Instructions("""
    You summarize lectures and discussions for a student who missed details. Use only what \
    the transcript actually says — never add claims, examples, or bullet points that aren't \
    supported by it. If the transcript is short or unclear, keep the summary short. Be neutral \
    and concise.
    """)

    private static let flashcardInstructions = Instructions("You write study flashcards. Each card has a clear question on the front and a correct, self-contained answer of one or two sentences on the back. Prefer understanding over trivia. Base every card strictly on the provided material.")

    private static let todoInstructions = Instructions("You extract action items from lecture transcripts. Only include concrete tasks the speaker actually assigned or recommended. For each, quote the exact sentence it came from.")
}

// MARK: - Generable schemas

@Generable
struct GeneratedDeck {
    @Guide(description: "Between 6 and 14 flashcards covering the key ideas, ordered as they came up")
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
    @Guide(description: "Every concrete action the student should take; empty if there are none")
    var tasks: [GeneratedTask]
}

@Generable
struct GeneratedTask {
    @Guide(description: "The action to take, phrased as a short imperative")
    var task: String
    @Guide(description: "A brief due-date hint if one was stated, e.g. \"Due Thursday\"; otherwise an empty string")
    var due: String
    @Guide(description: "The sentence from the transcript, quoted verbatim, that this task comes from")
    var source: String
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
