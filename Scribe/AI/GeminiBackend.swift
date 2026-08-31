import Foundation

/// Errors surfaced to the user by name (see `SessionDocument.aiMessage(for:)`).
enum GeminiError: LocalizedError {
    case noKey
    case keyRejected
    case rateLimited
    case offline
    case server(status: Int, detail: String)
    case emptyResponse
    case badJSON

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "No Gemini API key. Option-click the Sessions button to add one."
        case .keyRejected:
            return "That Gemini API key was rejected. Check it in Settings (Option-click Sessions)."
        case .rateLimited:
            return "Gemini is rate-limiting this key. Wait a moment and try again."
        case .offline:
            return "No connection. Switch to Apple Intelligence in Settings to keep working offline."
        case .server(let status, let detail):
            return "Gemini returned an error (\(status)). \(detail)"
        case .emptyResponse:
            return "Gemini returned nothing. Try again, or switch to Apple Intelligence."
        case .badJSON:
            return "Gemini's reply couldn't be read. Try again, or switch to Apple Intelligence."
        }
    }
}

/// The Google Gemini backend. Unlike the Apple path this sends the lecture transcript over
/// the network to Google's servers. Gemini's context is large enough that every pass is a
/// single call — no chunking, no map-reduce. `apiKey` and `model` are pushed in by
/// `IntelligenceService` whenever settings change.
@MainActor
@Observable
final class GeminiBackend: IntelligenceBackend {

    var apiKey: String?
    var model: String = ""

    var isAvailable: Bool { apiKey?.isEmpty == false && !model.isEmpty }

    var unavailableReason: String? {
        guard !isAvailable else { return nil }
        if apiKey?.isEmpty != false {
            return "Google Gemini is selected but has no API key. Option-click the Sessions button to add one."
        }
        return "Google Gemini is selected but no model is picked. Option-click the Sessions button to choose one."
    }

    private static let host = "https://generativelanguage.googleapis.com/v1beta"

    // MARK: Features

    func summarize(_ transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        onProgress?(1, 1)
        return try await generateText(
            system: Prompts.summary(bulletTarget: Self.bulletTarget(for: clean)),
            user: "Summarize this session.\n\n\(Prompts.wrap(clean))"
        )
    }

    func flashcards(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [Flashcard] {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        onProgress?(1, 1)

        let data = try await generateJSON(
            system: Prompts.flashcards,
            user: "Write flashcards from this material, covering its most important ideas, definitions and relationships in the order they appear. Write only as many as the material genuinely supports.\n\n\(Prompts.wrap(clean, tag: "MATERIAL"))",
            schema: [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "front": ["type": "STRING"],
                        "back": ["type": "STRING"],
                    ],
                    "required": ["front", "back"],
                ],
            ]
        )
        let cards = try Self.decode([GeminiCard].self, from: data)
        return cards
            .map { Flashcard(front: $0.front.trimmed, back: $0.back.trimmed) }
            .filter { !$0.front.isEmpty && !$0.back.isEmpty }
    }

    func todos(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [ExtractedTask] {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        onProgress?(1, 1)

        // Top-level object with a named array, mirroring the Apple `GeneratedTaskList` shape.
        let data = try await generateJSON(
            system: Prompts.todosWholeTranscript,
            user: "The complete lecture transcript follows. List every action item it assigns the student.\n\n\(Prompts.wrap(clean))",
            schema: [
                "type": "OBJECT",
                "properties": [
                    "tasks": [
                        "type": "ARRAY",
                        "items": [
                            "type": "OBJECT",
                            "properties": [
                                "source": ["type": "STRING"],
                                "task": ["type": "STRING"],
                                "due": ["type": "STRING"],
                            ],
                            "required": ["source", "task"],
                        ],
                    ],
                ],
                "required": ["tasks"],
            ]
        )
        let list = try Self.decode(GeminiTaskList.self, from: data)
        return list.tasks
            .filter { $0.task.trimmed.count > 3 }
            .map { ExtractedTask(task: $0.task.trimmed, source: $0.source.trimmed, due: $0.due?.trimmed.nilIfEmpty) }
    }

    func suggestedTitle(from transcript: String) async throws -> String {
        let sample = String(transcript.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
        guard sample.count > 40 else { return "" }

        let raw = try await generateText(
            system: Prompts.title,
            user: "Excerpt from a recording:\n\n\(Prompts.wrap(sample))"
        )
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'."))
        guard (1...8).contains(cleaned.split(separator: " ").count) else { return "" }
        return cleaned
    }

    func polishedNotes(_ notes: String) async throws -> String {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 20 else { return notes }

        let tidied = try await generateText(
            system: Prompts.notes,
            user: "Tidy these notes:\n\n\(Prompts.wrap(clean, tag: "NOTES"))"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Same guard as the Apple path: the result overwrites the student's writing with no
        // undo, so reject a pass that came back suspiciously short.
        guard !tidied.isEmpty, tidied.count >= (clean.count * 3) / 5 else {
            throw IntelligenceError.notesTidyLostContent
        }
        return tidied
    }

    // MARK: Key validation / model discovery

    /// Lists the models this key can call `generateContent` on. Doubles as key validation for
    /// the settings panel — a bad key throws `.keyRejected` here.
    static func listModels(key: String) async throws -> [String] {
        guard var components = URLComponents(string: "\(host)/models") else { throw GeminiError.badJSON }
        components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
        guard let url = components.url else { throw GeminiError.badJSON }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await send(request)
        try check(response, data: data)

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else { throw GeminiError.badJSON }

        return models.compactMap { entry -> String? in
            guard
                let name = entry["name"] as? String,
                let methods = entry["supportedGenerationMethods"] as? [String],
                methods.contains("generateContent")
            else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }

    // MARK: HTTP

    private func generateText(system: String, user: String) async throws -> String {
        let data = try await callGenerate(system: system, user: user, generationConfig: [
            "temperature": 0.4,
        ])
        guard let text = Self.firstText(in: data) else { throw GeminiError.emptyResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the raw JSON payload the model produced (already unwrapped from the envelope).
    private func generateJSON(system: String, user: String, schema: [String: Any]) async throws -> Data {
        let data = try await callGenerate(system: system, user: user, generationConfig: [
            "temperature": 0.2,
            "responseMimeType": "application/json",
            "responseSchema": schema,
        ])
        guard let text = Self.firstText(in: data), let payload = text.data(using: .utf8) else {
            throw GeminiError.emptyResponse
        }
        return payload
    }

    private func callGenerate(system: String, user: String, generationConfig: [String: Any]) async throws -> Data {
        guard let key = apiKey, !key.isEmpty else { throw GeminiError.noKey }
        guard !model.isEmpty, let url = URL(string: "\(Self.host)/models/\(model):generateContent") else {
            throw GeminiError.noKey
        }
        try Task.checkCancellation()

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": generationConfig,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.send(request)
        try Task.checkCancellation()
        try Self.check(response, data: data)
        return data
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .dataNotAllowed:
                throw GeminiError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw error
            }
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 400, 401, 403:
            throw GeminiError.keyRejected
        case 429:
            throw GeminiError.rateLimited
        default:
            var detail = ""
            if
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let err = root["error"] as? [String: Any],
                let message = err["message"] as? String {
                detail = String(message.prefix(160))
            }
            throw GeminiError.server(status: http.statusCode, detail: detail)
        }
    }

    /// Pulls `candidates[0].content.parts[*].text` out of a generateContent response.
    private static func firstText(in data: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = root["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GeminiError.badJSON }
    }

    /// Bullet target for the one-call summary path: scaled by transcript length, since there
    /// is no chunk count to scale by the way the Apple path does.
    private static func bulletTarget(for transcript: String) -> String {
        let words = transcript.split { $0 == " " || $0.isNewline }.count
        let low = min(10, max(4, words / 450))
        return "\(low) to \(min(14, low + 4))"
    }
}

// MARK: - Wire structs

private struct GeminiCard: Decodable { var front: String; var back: String }
private struct GeminiTask: Decodable { var task: String; var source: String; var due: String? }
private struct GeminiTaskList: Decodable { var tasks: [GeminiTask] }

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
