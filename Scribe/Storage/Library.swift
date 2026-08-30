import AppKit
import Foundation

/// Where one session's files live on disk.
struct SessionStore: Hashable {
    let folder: URL
    var meta: URL { folder.appendingPathComponent("session.json") }
    var transcript: URL { folder.appendingPathComponent("transcript.md") }
    var summary: URL { folder.appendingPathComponent("summary.md") }
    var notes: URL { folder.appendingPathComponent("notes.md") }
    var flashcards: URL { folder.appendingPathComponent("flashcards.json") }
    var todos: URL { folder.appendingPathComponent("todos.json") }
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
}

/// The user-chosen folder that holds every session. Access is kept alive for the app's
/// lifetime via a security-scoped bookmark.
@MainActor
@Observable
final class Library {

    private(set) var rootURL: URL?
    var errorMessage: String?

    var needsFolder: Bool { rootURL == nil }

    private static let bookmarkKey = "ScribeLibraryBookmark"

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
        } catch {
            errorMessage = "Couldn't delete that session: \(error.localizedDescription)"
        }
    }

    // MARK: Sessions

    func makeSession(title: String) throws -> SessionStore {
        guard let rootURL else { throw ScribeError.noLibraryFolder }
        let safeTitle = sanitize(title)
        let name = "\(Self.folderStamp.string(from: .now)) \(safeTitle)"
        let folder = rootURL.appendingPathComponent(name, isDirectory: true)
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
        let transcriptText = (try? String(contentsOf: store.transcript, encoding: .utf8)) ?? ""
        return LoadedSession(
            meta: ref.meta,
            store: store,
            segments: TranscriptLayout.parseMarkdown(transcriptText),
            summary: (try? String(contentsOf: store.summary, encoding: .utf8)) ?? "",
            notes: (try? String(contentsOf: store.notes, encoding: .utf8)) ?? "",
            flashcards: decode([Flashcard].self, from: store.flashcards) ?? [],
            todos: decode([TodoItem].self, from: store.todos) ?? []
        )
    }

    // MARK: Writing

    func write(meta: SessionMeta,
               store: SessionStore,
               segments: [TranscriptSegment],
               summary: String,
               notes: String,
               flashcards: [Flashcard],
               todos: [TodoItem]) {
        do {
            try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
            try JSONEncoder.scribe.encode(meta).write(to: store.meta, options: .atomic)
            try transcriptMarkdown(meta: meta, segments: segments)
                .data(using: .utf8)?.write(to: store.transcript, options: .atomic)
            try write(text: summary, to: store.summary)
            try write(text: notes, to: store.notes)
            try JSONEncoder.scribe.encode(flashcards).write(to: store.flashcards, options: .atomic)
            try JSONEncoder.scribe.encode(todos).write(to: store.todos, options: .atomic)
        } catch {
            errorMessage = "Couldn't save this session: \(error.localizedDescription)"
        }
    }

    private func write(text: String, to url: URL) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private func transcriptMarkdown(meta: SessionMeta, segments: [TranscriptSegment]) -> String {
        var out = "# \(meta.title)\n\n"
        out += "_\(Self.dateline.string(from: meta.createdAt))"
        if meta.duration > 1 { out += " · \(timecode(meta.duration))" }
        out += "_\n\n"

        for paragraph in TranscriptLayout.paragraphs(from: segments) {
            out += "**[\(paragraph.marker)]** \(paragraph.text)\n\n"
        }
        return out
    }

    private static let dateline: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

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
