@preconcurrency import AVFoundation
import CoreMedia
import Speech

/// Live microphone transcription built on macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
/// Everything runs on-device. Finalized phrases are reported with their start time in the
/// recording so the rest of the app can jump back to them.
@MainActor
@Observable
final class Transcriber {

    enum Phase: Equatable {
        case idle
        case requestingPermission
        case preparingModel
        case running
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    var isRunning: Bool { phase == .running }

    /// Called for each finalized phrase: `(text, startSeconds)`.
    @ObservationIgnored var onFinalSegment: ((String, TimeInterval) -> Void)?
    /// Called with the in-progress ("volatile") phrase as it firms up.
    @ObservationIgnored var onVolatile: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var tapInstalled = false

    // MARK: Lifecycle

    func start(locale: Locale) async {
        guard !isRunning else { return }
        phase = .requestingPermission

        guard await ensurePermissions() else {
            phase = .unavailable("Scribe needs microphone access. Turn it on in System Settings › Privacy & Security › Microphone.")
            return
        }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        do {
            try await ensureModelInstalled(for: transcriber, locale: resolvedLocale)
        } catch {
            phase = .unavailable("Couldn't prepare the on-device model for \(languageName(locale)).")
            return
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            phase = .unavailable("This Mac couldn't provide audio in a format the transcriber accepts.")
            return
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self, !text.isEmpty else { continue }
                    let start = max(0, result.range.start.seconds.isFinite ? result.range.start.seconds : 0)
                    if result.isFinal {
                        self.onFinalSegment?(text, start)
                    } else {
                        self.onVolatile?(text)
                    }
                }
            } catch {
                self?.phase = .unavailable("Transcription stopped: \(error.localizedDescription)")
            }
        }

        do {
            try startEngine(feeding: continuation, outputFormat: analyzerFormat)
            try await analyzer.start(inputSequence: inputStream)
            phase = .running
            #if DEBUG
            print("[Scribe] transcriber running, format=\(analyzerFormat)")
            #endif
        } catch {
            await stop()
            phase = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
            #if DEBUG
            print("[Scribe] start failed: \(error)")
            #endif
        }
    }

    func stop() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
        switch phase {
        case .running, .preparingModel, .requestingPermission:
            phase = .idle
        default:
            break
        }
    }

    // MARK: Audio engine

    private func startEngine(feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
                             outputFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let converter: AVAudioConverter? = inputFormat == outputFormat
            ? nil
            : AVAudioConverter(from: inputFormat, to: outputFormat)

        // Explicitly `@Sendable` so the realtime tap thread carries no actor expectations
        // (a main-actor-isolated tap block trips Swift's executor assertion and crashes).
        let block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

            var conversionError: NSError?
            let source = SingleBuffer(buffer)
            converter.convert(to: output, error: &conversionError) { _, status in
                if let next = source.take() {
                    status.pointee = .haveData
                    return next
                }
                status.pointee = .noDataNow
                return nil
            }
            if conversionError == nil, output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: block)
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    // MARK: Permissions & model

    private func ensurePermissions() async -> Bool {
        // Ask for speech access so the prompt appears; on-device transcription itself
        // gates on the microphone, which we require.
        _ = await Self.requestSpeechAuthorization()
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// `nonisolated` on purpose: TCC calls the completion handler on a background queue,
    /// and a main-actor-isolated closure there would trip Swift's executor assertion.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func ensureModelInstalled(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let wanted = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == wanted }
        guard !installed else { return }
        phase = .preparingModel
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    private func languageName(_ locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// Hands an `AVAudioConverter` its single input buffer once, then nil.
private final class SingleBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Languages

enum SpeechLanguages {
    /// Locales the current Mac can transcribe, sorted by localized name.
    static func available() async -> [Locale] {
        let locales = await SpeechTranscriber.supportedLocales
        let base = locales.isEmpty ? [Locale(identifier: "en-US")] : locales
        return base.sorted { name(for: $0).localizedCaseInsensitiveCompare(name(for: $1)) == .orderedAscending }
    }

    static func name(for locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier)
            ?? Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    /// A reasonable default before the supported list has loaded; the transcriber
    /// resolves this to an actually-supported locale when recording starts.
    static var preferred: Locale {
        Locale.current
    }
}
