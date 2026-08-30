import AppKit
import Foundation

/// Where one session's files live on disk.
struct SessionStore: Hashable, Sendable {
    let folder: URL
    var meta: URL { folder.appendingPathComponent("session.json") }
    var transcript: URL { folder.appendingPathComponent("transcript.md") }
    /// Authoritative timed transcript — one JSON segment per line, appended as we go.
    var segments: URL { folder.appendingPathComponent("segments.jsonl") }
    var summary: URL { folder.appendingPathComponent("summary.md") }
    var notes: URL { folder.appendingPathComponent("notes.md") }
    var flashcards: URL { folder.appendingPathComponent("flashcards.json") }
    var todos: URL { folder.appendingPathComponent("todos.json") }
    var bookmarks: URL { folder.appendingPathComponent("bookmarks.json") }
}

struct SessionRef: Identifiable, Hashable {
    var meta: SessionMeta
    var store: SessionStore
    var id: UUID { meta.id }
}

/// Snapshot of a session loaded from disk.
struct LoadedSession {
    var meta: SessionMeta
    var store: SessionStore
    var segments: [TranscriptSegment]
    var summary: String
    var notes: String
    var flashcards: [Flashcard]
    var todos: [TodoItem]
    var bookmarks: [Bookmark]
}

/// An immutable copy of everything a session persists — safe to hand to the background writer.
struct SessionSnapshot: Sendable {
    var meta: SessionMeta
    var store: SessionStore
    var segments: [TranscriptSegment]
    var summary: String
    var notes: String
    var flashcards: [Flashcard]
    var todos: [TodoItem]
    var bookmarks: [Bookmark]
}

/// The user-chosen folder that holds every session. Access is kept alive for the app's
/// lifetime via a security-scoped bookmark.
@MainActor
@Observable
final class Library {

    private(set) var rootURL: URL?
    /// Surfaced modally — only for failures of an action the user just took (choose folder, delete).
    var errorMessage: String?
    /// Surfaced as a quiet inline banner — background autosave trouble, coalesced so a full
    /// disk during a lecture can't produce an alert storm.
    private(set) var saveTrouble: String?

    var needsFolder: Bool { rootURL == nil }

    private static let bookmarkKey = "ScribeLibraryBookmark"
    private let writer = SessionWriter()
    /// Folders that have just been moved to the Trash — a save that was already queued for one
    /// of these must be dropped rather than allowed to recreate it.
    private var trashedFolders: Set<URL> = []

    private static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    init() {
        resolveBookmark()
    }

    // MARK: Folder selection

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder where Scribe will save your transcripts, notes, flashcards and to-dos."
        if let existing = rootURL { panel.directoryURL = existing.deletingLastPathComponent() }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL?.stopAccessingSecurityScopedResource()
        rootURL = url
        storeBookmark(url)
    }

    #if DEBUG
    /// Uses a folder inside the app sandbox container — always writable, no bookmark needed.
    func useContainerFolderForTesting() {
        let base = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("ScribeTestLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rootURL = folder
        print("[Scribe] test library: \(folder.path)")
    }
    #endif

    private func storeBookmark(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            _ = url.startAccessingSecurityScopedResource()
        } catch {
            errorMessage = "Couldn't remember that folder: \(error.localizedDescription)"
        }
    }

    private func resolveBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale)
        else { return }
        if url.startAccessingSecurityScopedResource() {
            rootURL = url
            if stale { storeBookmark(url) }
        }
    }

    func reveal(_ store: SessionStore) {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder])
    }

    /// Moves a session's folder to the Trash (recoverable), rather than deleting outright.
    func deleteSession(_ ref: SessionRef) {
        do {
            try FileManager.default.trashItem(at: ref.store.folder, resultingItemURL: nil)
            trashedFolders.insert(ref.store.folder)
        } catch {
            errorMessage = "Couldn't delete that session: \(error.localizedDescription)"
        }
    }

    // MARK: Health checks

    /// Bytes of usable space where sessions are saved, or nil if it can't be read.
    func availableCapacity() -> Int64? {
        guard let rootURL else { return nil }
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// True if the chosen folder is still reachable (external drive still mounted, etc.).
    func rootReachable() -> Bool {
        guard let rootURL else { return false }
        return (try? rootURL.checkResourceIsReachable()) == true
    }

    // MARK: Sessions

    func makeSession(title: String) throws -> SessionStore {
        guard let rootURL else { throw ScribeError.noLibraryFolder }
        let safeTitle = sanitize(title)
        let base = "\(Self.folderStamp.string(from: .now)) \(safeTitle)"

        // The stamp is minute-precision, so two sessions started in the same minute with the
        // same title (e.g. two "New Session"s) would otherwise land in the same folder and
        // autosave over each other — `createDirectory` doesn't complain about an existing dir.
        var folder = rootURL.appendingPathComponent(base, isDirectory: true)
        var attempt = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = rootURL.appendingPathComponent("\(base) (\(attempt))", isDirectory: true)
            attempt += 1
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ScribeError.couldNotCreateSession(error.localizedDescription)
        }
        return SessionStore(folder: folder)
    }

    func sessions() -> [SessionRef] {
        guard let rootURL else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries.compactMap { folder -> SessionRef? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let store = SessionStore(folder: folder)
            guard let data = try? Data(contentsOf: store.meta),
                  let meta = try? JSONDecoder.scribe.decode(SessionMeta.self, from: data)
            else { return nil }
            return SessionRef(meta: meta, store: store)
        }
        .sorted { $0.meta.createdAt > $1.meta.createdAt }
    }

    func load(_ ref: SessionRef) -> LoadedSession {
        let store = ref.store
        return LoadedSession(
            meta: ref.meta,
            store: store,
            segments: Self.loadSegments(store),
            summary: (try? String(contentsOf: store.summary, encoding: .utf8)) ?? "",
            notes: (try? String(contentsOf: store.notes, encoding: .utf8)) ?? "",
            flashcards: decode([Flashcard].self, from: store.flashcards) ?? [],
            todos: decode([TodoItem].self, from: store.todos) ?? [],
            bookmarks: decode([Bookmark].self, from: store.bookmarks) ?? []
        )
    }

    /// Prefer the loss-free `segments.jsonl`; fall back to parsing older `transcript.md` files.
    private static func loadSegments(_ store: SessionStore) -> [TranscriptSegment] {
        if let data = try? Data(contentsOf: store.segments), !data.isEmpty {
            let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            let decoder = JSONDecoder.scribe
            let parsed = lines.compactMap { try? decoder.decode(TranscriptSegment.self, from: Data($0)) }
            if !parsed.isEmpty { return parsed }
        }
        let markdown = (try? String(contentsOf: store.transcript, encoding: .utf8)) ?? ""
        return TranscriptLayout.parseMarkdown(markdown)
    }

    // MARK: Writing

    /// Hands a value copy to the background writer; failures come back as a coalesced banner.
    func save(_ snapshot: SessionSnapshot) {
        guard !trashedFolders.contains(snapshot.store.folder) else { return }
        let writer = self.writer
        Task { [weak self] in
            let trouble = await writer.write(snapshot)
            await MainActor.run {
                guard let self, !self.trashedFolders.contains(snapshot.store.folder) else { return }
                self.saveTrouble = trouble
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.scribe.decode(T.self, from: data)
    }

    private func sanitize(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        let collapsed = cleaned.replacingOccurrences(of: "  ", with: " ")
        return collapsed.isEmpty ? "Untitled Session" : String(collapsed.prefix(80))
    }
}

// MARK: - Background writer

/// Serializes every session write onto one actor, off the main thread, so a 4-hour transcript
/// being flushed can't stutter the UI. Returns a message on failure, nil on success.
actor SessionWriter {

    private static let dateline: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private lazy var lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    func write(_ s: SessionSnapshot) -> String? {
        do {
            try FileManager.default.createDirectory(at: s.store.folder, withIntermediateDirectories: true)
            try JSONEncoder.scribe.encode(s.meta).write(to: s.store.meta, options: .atomic)

            var jsonl = Data()
            for segment in s.segments {
                jsonl.append(try lineEncoder.encode(segment))
                jsonl.append(UInt8(ascii: "\n"))
            }
            try jsonl.write(to: s.store.segments, options: .atomic)

            try Self.markdown(meta: s.meta, segments: s.segments)
                .data(using: .utf8)?.write(to: s.store.transcript, options: .atomic)

            try writeText(s.summary, to: s.store.summary)
            try writeText(s.notes, to: s.store.notes)
            try JSONEncoder.scribe.encode(s.flashcards).write(to: s.store.flashcards, options: .atomic)
            try JSONEncoder.scribe.encode(s.todos).write(to: s.store.todos, options: .atomic)

            if s.bookmarks.isEmpty {
                try? FileManager.default.removeItem(at: s.store.bookmarks)
            } else {
                try JSONEncoder.scribe.encode(s.bookmarks).write(to: s.store.bookmarks, options: .atomic)
            }
            return nil
        } catch {
            return "Couldn't save this session: \(error.localizedDescription)"
        }
    }

    private func writeText(_ text: String, to url: URL) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private static func markdown(meta: SessionMeta, segments: [TranscriptSegment]) -> String {
        var out = "# \(meta.title)\n\n"
        out += "_\(dateline.string(from: meta.createdAt))"
        if meta.duration > 1 { out += " · \(timecode(meta.duration))" }
        out += "_\n\n"
        for paragraph in TranscriptLayout.paragraphs(from: segments) {
            out += "**[\(paragraph.marker)]** \(paragraph.text)\n\n"
        }
        return out
    }
}
