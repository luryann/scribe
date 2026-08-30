import Foundation

// MARK: - Stored models

/// One finalized span of transcript, tagged with when it was said (seconds into the recording).
struct TranscriptSegment: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var start: TimeInterval
}

struct Flashcard: Identifiable, Codable, Hashable {
    var id = UUID()
    var front: String
    var back: String
}

struct TodoItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var isDone: Bool = false
    /// A short human hint like "Due Thursday", when the speaker gave one.
    var dueHint: String?
    /// The sentence from the transcript this task was pulled from.
    var sourceQuote: String?
    /// Resolved position of `sourceQuote` in the recording, in seconds. Drives "jump to source".
    var sourceTime: TimeInterval?
}

struct SessionMeta: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval
    /// Folder name inside the Scribe library that holds this session's files.
    var folderName: String
}

// MARK: - Tabs

enum MainTab: String, CaseIterable, Identifiable {
    case live, summary, notes, cards, todos
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .summary: "Summary"
        case .notes: "Notes"
        case .cards: "Cards"
        case .todos: "To-Do"
        }
    }

    var symbol: String {
        switch self {
        case .live: "waveform"
        case .summary: "doc.text"
        case .notes: "square.and.pencil"
        case .cards: "rectangle.on.rectangle.angled"
        case .todos: "checklist"
        }
    }
}

// MARK: - Errors

enum ScribeError: LocalizedError {
    case noLibraryFolder
    case couldNotCreateSession(String)

    var errorDescription: String? {
        switch self {
        case .noLibraryFolder:
            "Choose a folder for Scribe to save into first."
        case .couldNotCreateSession(let why):
            "Couldn't start a new session: \(why)"
        }
    }
}

// MARK: - Formatting helpers

/// `m:ss` or `h:mm:ss` for elapsed time and transcript markers.
func timecode(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let s = total % 60, m = (total / 60) % 60, h = total / 3600
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}

extension JSONEncoder {
    static var scribe: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var scribe: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Transcript presentation

/// A run of transcript shown together under one timestamp marker.
struct TranscriptParagraph: Identifiable {
    let id: UUID          // id of the first segment, so views can scroll to it
    let start: TimeInterval
    let marker: String
    let text: String
}

enum TranscriptLayout {
    /// Groups segments into readable paragraphs, starting a new one whenever there's
    /// a >= 18s gap since the last marker (or every ~6 segments).
    static func paragraphs(from segments: [TranscriptSegment]) -> [TranscriptParagraph] {
        var result: [TranscriptParagraph] = []
        var bucket: [TranscriptSegment] = []
        var markerTime: TimeInterval = -.greatestFiniteMagnitude

        func flush() {
            guard let first = bucket.first else { return }
            result.append(
                TranscriptParagraph(
                    id: first.id,
                    start: first.start,
                    marker: timecode(first.start),
                    text: bucket.map(\.text).joined(separator: " ")
                )
            )
            bucket.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            if !bucket.isEmpty, segment.start - markerTime >= 18 || bucket.count >= 6 {
                flush()
            }
            if bucket.isEmpty { markerTime = segment.start }
            bucket.append(segment)
        }
        flush()
        return result
    }

    /// Rebuilds a timed segment list from a `transcript.md` file that Scribe wrote earlier.
    static func parseMarkdown(_ markdown: String) -> [TranscriptSegment] {
        let pattern = /\*\*\[(\d+):(\d{2})(?::(\d{2}))?\]\*\*\s*/
        var segments: [TranscriptSegment] = []
        var pending: (start: TimeInterval, text: String)?

        func commit() {
            if let p = pending {
                let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { segments.append(TranscriptSegment(text: text, start: p.start)) }
            }
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("#") || line.hasPrefix("_") { continue }
            if let match = line.firstMatch(of: pattern) {
                commit()
                let a = Int(match.output.1) ?? 0
                let b = Int(match.output.2) ?? 0
                let c = match.output.3.flatMap { Int($0) }
                let seconds = c == nil ? TimeInterval(a * 60 + b) : TimeInterval(a * 3600 + b * 60 + (c ?? 0))
                let rest = String(line[match.range.upperBound...])
                pending = (seconds, rest)
            } else if pending != nil {
                pending?.text += " " + line
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                pending = (0, line)
            }
        }
        commit()
        return segments
    }
}

// MARK: - Source matching

enum TranscriptMatcher {
    /// Finds when a quoted sentence was spoken by matching it against the timed segments.
    static func time(for quote: String, in segments: [TranscriptSegment]) -> TimeInterval? {
        let needle = quote.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 10, !segments.isEmpty else { return nil }

        let needleWords = Set(needle.split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 })
        guard !needleWords.isEmpty else { return nil }

        var best: (score: Double, time: TimeInterval)?
        for segment in segments {
            let hay = segment.text.lowercased()
            if hay.contains(needle) || needle.contains(hay), hay.count > 12 {
                return segment.start
            }
            let hayWords = Set(hay.split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 })
            let overlap = Double(needleWords.intersection(hayWords).count) / Double(needleWords.count)
            if overlap >= 0.5, best == nil || overlap > best!.score {
                best = (overlap, segment.start)
            }
        }
        return best?.time
    }
}
