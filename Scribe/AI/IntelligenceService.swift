import Foundation

/// Which model Scribe routes its AI passes through.
enum AIProvider: String, CaseIterable, Identifiable {
    case apple, gemini
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:  "Apple Intelligence"
        case .gemini: "Google Gemini"
        }
    }

    var blurb: String {
        switch self {
        case .apple:  "On-device · works offline · free"
        case .gemini: "Higher quality · sends transcript text to Google"
        }
    }
}

/// Routes every AI request to the chosen backend and keeps the two of them configured.
/// `AppleIntelligenceBackend` is always present as the offline fallback; `GeminiBackend`
/// runs when the user has picked Gemini and entered an API key.
///
/// The public method surface is unchanged from before the provider switch existed, so
/// `SessionDocument` and the views don't know which backend answered.
@MainActor
@Observable
final class IntelligenceService {

    let apple = AppleIntelligenceBackend()
    @ObservationIgnored let gemini = GeminiBackend()

    /// Chosen provider. Stored (not computed over UserDefaults) so `@Observable` tracks it and
    /// the footer button re-evaluates the moment it flips — same rule as
    /// `Transcriber.preferredInputUID`.
    var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
        }
    }

    /// Model id for the Gemini path (e.g. "gemini-2.5-flash"). Stored + mirrored like `provider`.
    var geminiModel: String {
        didSet {
            guard geminiModel != oldValue else { return }
            UserDefaults.standard.set(geminiModel, forKey: Self.modelKey)
            gemini.model = geminiModel
        }
    }

    /// Whether a Gemini key is stored. A stored flag, not a defaults read, so views observing
    /// availability update when the key is added or cleared.
    private(set) var hasGeminiKey: Bool

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.gemini.model"
    private static let apiKeyKey = "ai.gemini.apiKey"

    init() {
        let savedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
        provider = AIProvider(rawValue: savedProvider ?? "") ?? .apple
        geminiModel = UserDefaults.standard.string(forKey: Self.modelKey) ?? ""

        let key = UserDefaults.standard.string(forKey: Self.apiKeyKey)
        hasGeminiKey = key?.isEmpty == false
        gemini.apiKey = key
        gemini.model = geminiModel
    }

    // MARK: Settings

    /// Stores (or clears, on nil/empty) the Gemini API key and pushes it into the backend.
    ///
    /// The key is kept in `UserDefaults`, not the Keychain: this app is ad-hoc signed
    /// (`CODE_SIGN_IDENTITY = -`, no team), so the data-protection Keychain returns
    /// `errSecMissingEntitlement` and the file-based Keychain re-prompts for the login
    /// password on every rebuild (the signature changes each build, invalidating the item
    /// ACL). For a local, single-user, personal app holding one Gemini API key, the sandbox
    /// container plist is an acceptable home.
    func setGeminiKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: Self.apiKeyKey)
            gemini.apiKey = trimmed
            hasGeminiKey = true
        } else {
            UserDefaults.standard.removeObject(forKey: Self.apiKeyKey)
            gemini.apiKey = nil
            hasGeminiKey = false
        }
    }

    var geminiKey: String? { UserDefaults.standard.string(forKey: Self.apiKeyKey) }

    // MARK: Availability (forwarded to the active backend)

    private var active: any IntelligenceBackend {
        provider == .gemini ? gemini : apple
    }

    /// Computed over the *observed* stored properties (`provider`, `hasGeminiKey`,
    /// `geminiModel`, and `apple`'s own observed flags) — never over the Keychain or the
    /// `@ObservationIgnored` `gemini` config — so SwiftUI re-evaluates the footer button the
    /// instant the provider or key changes.
    var isAvailable: Bool {
        switch provider {
        case .apple:  apple.isAvailable
        case .gemini: hasGeminiKey && !geminiModel.isEmpty
        }
    }

    var unavailableReason: String? {
        guard !isAvailable else { return nil }
        switch provider {
        case .apple:
            return apple.unavailableReason
        case .gemini:
            return hasGeminiKey
                ? "Google Gemini is selected but no model is picked — Option-click the Sessions button to choose one."
                : "Google Gemini is selected but has no API key — Option-click the Sessions button to add one."
        }
    }

    /// Re-checks the on-device model (Apple Intelligence can come online while the app runs).
    func refreshAvailability() {
        apple.refreshAvailability()
    }

    // MARK: Passes

    func summarize(_ transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> String {
        try await active.summarize(transcript, onProgress: onProgress)
    }

    func flashcards(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [Flashcard] {
        try await active.flashcards(from: transcript, onProgress: onProgress)
    }

    func todos(from transcript: String, onProgress: ((Int, Int) -> Void)? = nil) async throws -> [ExtractedTask] {
        try await active.todos(from: transcript, onProgress: onProgress)
    }

    func suggestedTitle(from transcript: String) async throws -> String {
        try await active.suggestedTitle(from: transcript)
    }

    func polishedNotes(_ notes: String) async throws -> String {
        try await active.polishedNotes(notes)
    }
}
