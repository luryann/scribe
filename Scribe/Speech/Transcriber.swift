@preconcurrency import AVFoundation
import AppKit
import CoreMedia
import Speech
import Synchronization

/// Live microphone transcription built on macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
/// Everything runs on-device. Finalized phrases are reported with their start time in the
/// recording so the rest of the app can jump back to them.
///
/// Built to survive a multi-hour lecture: a monotonic audio-frame clock that stays continuous
/// across engine restarts, automatic recovery from audio route changes and system wake, a real
/// input-level meter that can tell when the mic has gone dead, and an idle-sleep / App-Nap
/// assertion so a backgrounded recording keeps running.
@MainActor
@Observable
final class Transcriber {

    enum Phase: Equatable {
        case idle
        case requestingPermission
        /// Downloading / preparing the on-device model. Payload is 0...1 progress, or -1 when unknown.
        case preparingModel(Double)
        case running
        case paused
        /// Recording halted unexpectedly (route lost, engine error). Recoverable — the user can resume.
        case interrupted(String)
        /// Not usable in this session (no permission, no model, unsupported Mac).
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    var isRunning: Bool { phase == .running }
    var isPaused: Bool { if case .paused = phase { true } else { false } }
    var isInterrupted: Bool { if case .interrupted = phase { true } else { false } }
    /// True whenever a recording is in progress from the user's point of view (incl. paused / preparing).
    var isActive: Bool {
        switch phase {
        case .running, .paused, .requestingPermission, .preparingModel: true
        case .idle, .interrupted, .unavailable: false
        }
    }

    /// Smoothed overall input level, 0...1 — used for the dead-mic check.
    private(set) var inputLevel: Float = 0
    /// A rolling window of the most recent peak readings (newest last), refreshed ~30×/sec so
    /// the on-screen meter tracks the actual sound in the room, not a canned animation.
    private(set) var meterLevels: [Float] = Array(repeating: 0, count: 13)
    /// Seconds of continuous near-silence while recording; 0 while sound is present.
    private(set) var silenceDuration: TimeInterval = 0
    /// Audio actually captured, in seconds — a monotonic clock that ignores setup and pauses.
    var audioSeconds: TimeInterval { Double(clock.frames.load(ordering: .relaxed)) / clockRate }
    /// Human name of the input device currently feeding (or about to feed) the engine.
    private(set) var inputDeviceName = "the microphone"

    private static let inputUIDKey = "ScribeInputDeviceUID"

    /// The microphone the user picked, by CoreAudio UID. `nil` means "let Scribe choose"
    /// (built-in mic, never Bluetooth). A real stored property so SwiftUI observes it;
    /// mirrored to `UserDefaults` so it survives relaunch.
    var preferredInputUID: String? {
        didSet {
            guard preferredInputUID != oldValue else { return }
            UserDefaults.standard.setValue(preferredInputUID, forKey: Self.inputUIDKey)
            refreshInputDevice()
        }
    }

    init() {
        preferredInputUID = UserDefaults.standard.string(forKey: Self.inputUIDKey)
    }

    /// The input device Scribe will actually record from, applying the user's choice or the
    /// built-in-first fallback.
    func resolvedInput() -> AudioInputDevice? {
        if let uid = preferredInputUID, let device = AudioDevices.device(uid: uid) {
            return device
        }
        return AudioDevices.preferredDefault()
    }

    /// Refresh the displayed input name (call when idle, e.g. after a device is plugged in).
    func refreshInputDevice() {
        guard !isActive else { return }
        inputDeviceName = resolvedInput()?.name ?? Self.currentInputName()
    }

    /// Called for each finalized phrase: `(text, startSeconds)`.
    @ObservationIgnored var onFinalSegment: ((String, TimeInterval) -> Void)?
    /// Called with the in-progress ("volatile") phrase as it firms up.
    @ObservationIgnored var onVolatile: ((String) -> Void)?
    /// Called once, on the main actor, after an unexpected halt has been torn down — so the
    /// owning document can flush a save immediately.
    @ObservationIgnored var onInterrupted: (() -> Void)?
    /// Called on the main actor when the Mac slept mid-recording (e.g. the lid closed) and woke
    /// again — payload is roughly how many seconds of audio were missed.
    @ObservationIgnored var onGap: ((TimeInterval) -> Void)?
    /// Called on the main actor after an automatic recovery has restored a running recording,
    /// so the owning document can restart anything it tore down in `onInterrupted`.
    @ObservationIgnored var onResumed: (() -> Void)?

    // Recreated for every recording: `AUAudioUnit.setDeviceID` is rejected once the unit has
    // been initialised, so a fresh engine is the only reliable way to switch microphones.
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var tapInstalled = false
    @ObservationIgnored private var analyzerFormat: AVAudioFormat?

    /// Shared with the realtime tap thread. `frames` is a monotonic audio clock in
    /// analyzer-format frames (seeded from any prior recorded duration so a reopened session
    /// keeps a continuous timeline); `level` is the peak amplitude since the meter last read it.
    @ObservationIgnored private let clock = AudioClock()
    @ObservationIgnored private var clockRate: Double = 16_000
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoudAt = Date.now

    @ObservationIgnored private var configObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var sleepObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var sleptAt: Date?
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var configSettleUntil = Date.distantPast
    @ObservationIgnored private var configRebuilds = 0
    @ObservationIgnored private var activityToken: (any NSObjectProtocol)?
    @ObservationIgnored private var reservedLocale: Locale?
    @ObservationIgnored private var activeLocale = Locale.current
    /// Added to every segment's analyzer-relative timestamp so a restarted `SpeechAnalyzer`
    /// (which always numbers its output from zero) keeps producing timestamps that continue
    /// the recording's timeline instead of colliding with earlier segments.
    @ObservationIgnored private var segmentTimeOffset: TimeInterval = 0
    /// Bumped by every `beginSession` and every `stop()`. An in-flight `beginSession` compares
    /// against it after each `await` and abandons itself if a newer start — or a stop — landed
    /// while it was waiting (e.g. during a multi-second model download).
    @ObservationIgnored private var sessionGeneration = 0

    // MARK: Lifecycle

    /// - Parameter startOffset: seconds of audio already recorded for this session, so the
    ///   frame clock (and every new segment's timestamp) continues from there.
    func start(locale: Locale, startOffset: TimeInterval = 0) async {
        guard !isRunning, !isPaused else { return }
        restartAttempts = 0
        await beginSession(locale: locale, startOffset: max(0, startOffset))
    }

    private func beginSession(locale: Locale, startOffset: TimeInterval) async {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        phase = .requestingPermission

        guard await ensurePermissions() else {
            guard generation == sessionGeneration else { return }
            phase = .unavailable("Scribe needs microphone access. Turn it on in System Settings › Privacy & Security › Microphone.")
            return
        }
        guard generation == sessionGeneration else { return }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        activeLocale = resolvedLocale
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        do {
            try await ensureModelInstalled(for: transcriber, locale: resolvedLocale)
        } catch {
            guard generation == sessionGeneration else { return }
            phase = .unavailable("Couldn't prepare the on-device model for \(languageName(resolvedLocale)).")
            return
        }

        // A stop() (or a newer start) landed while we were preparing — abandon this attempt
        // before we touch any hardware.
        guard generation == sessionGeneration else { return }

        // Fresh engine, then point it at the chosen mic *before* anything reads its format.
        engine = AVAudioEngine()
        applyInputDevice()

        let naturalFormat = engine.inputNode.inputFormat(forBus: 0)
        var format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: naturalFormat.sampleRate > 0 ? naturalFormat : nil
        )
        if format == nil {
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        guard let format else {
            guard generation == sessionGeneration else { return }
            phase = .unavailable("This Mac couldn't provide audio in a format the transcriber accepts.")
            return
        }
        analyzerFormat = format
        clockRate = format.sampleRate > 0 ? format.sampleRate : 16_000
        clock.frames.store(Int64(startOffset * clockRate), ordering: .relaxed)
        segmentTimeOffset = startOffset

        // Superseded by a stop() (or newer start) while probing formats? Bail before we
        // allocate the analyzer, streams and results task.
        guard generation == sessionGeneration else { return }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(400)   // ~30s of audio; a stalled analyzer can't run us out of memory
        )
        self.continuation = continuation

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        )
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self, !text.isEmpty else { continue }
                    let rawStart = result.range.start.seconds
                    let start = self.segmentTimeOffset + max(0, rawStart.isFinite ? rawStart : 0)
                    if result.isFinal {
                        self.onFinalSegment?(text, start)
                    } else {
                        self.onVolatile?(text)
                    }
                }
            } catch {
                await self?.handleFailure(error)
            }
        }

        do {
            try startEngine(feeding: continuation, outputFormat: format)
            try await analyzer.start(inputSequence: inputStream)
            guard generation == sessionGeneration else {
                await teardownEngine()
                continuation.finish()
                self.continuation = nil
                resultsTask?.cancel()
                resultsTask = nil
                self.analyzer = nil
                self.transcriber = nil
                return
            }
            beginActivityAssertion()
            observeAudioLifecycle()
            startMeter()
            phase = .running
            #if DEBUG
            print("[Scribe] transcriber running, format=\(format), device=\(inputDeviceName)")
            #endif
        } catch {
            await teardownEngine()
            phase = .unavailable("Couldn't start the microphone: \(error.localizedDescription)")
            #if DEBUG
            print("[Scribe] start failed: \(error)")
            #endif
        }
    }

    func stop() async {
        sessionGeneration &+= 1
        stopObservers()
        stopMeter()
        endActivityAssertion()

        // Order matters: stop feeding audio, then let the analyzer flush its tail onto
        // `results`, then let the consuming loop drain to completion before we drop it.
        await teardownEngine()
        continuation?.finish()
        continuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Let the results loop drain the analyzer's tail — but never hang on it.
        if let resultsTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await resultsTask.value }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            resultsTask.cancel()
        }
        resultsTask = nil
        analyzer = nil
        transcriber = nil

        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }

        inputLevel = 0
        silenceDuration = 0
        switch phase {
        case .running, .paused, .preparingModel, .requestingPermission, .interrupted:
            phase = .idle
        default:
            break
        }
    }

    // MARK: Pause / resume

    func pause() {
        guard case .running = phase else { return }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.pause()
        stopMeter()
        inputLevel = 0
        phase = .paused
    }

    func resume() async {
        guard case .paused = phase, let format = analyzerFormat, let continuation else { return }
        do {
            try startEngine(feeding: continuation, outputFormat: format)
            startMeter()
            phase = .running
        } catch {
            await handleFailure(error)
        }
    }

    /// User-driven retry after `.interrupted`.
    func resumeFromInterruption() async {
        guard isInterrupted else { return }
        restartAttempts = 0
        await beginSession(locale: activeLocale, startOffset: audioSeconds)
    }

    // MARK: Recovery

    private func handleFailure(_ error: any Error) async {
        // A cancelled results task (deliberate teardown in `stop()` or a superseded
        // `beginSession`) is not a reason to interrupt or auto-restart.
        if error is CancellationError { return }
        guard !recovering else { return }
        recovering = true
        defer { recovering = false }

        stopObservers()
        stopMeter()
        await teardownEngine()
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        inputLevel = 0

        onInterrupted?()

        if restartAttempts < 1 {
            restartAttempts += 1
            #if DEBUG
            print("[Scribe] auto-restarting after failure: \(error)")
            #endif
            await beginSession(locale: activeLocale, startOffset: audioSeconds)
            if case .running = phase {
                onResumed?()
                return
            }
        }

        endActivityAssertion()
        phase = .interrupted(Self.message(for: error))
    }

    private func handleConfigurationChange() {
        guard case .running = phase, !recovering, let format = analyzerFormat, let continuation else { return }
        // Ignore the burst of change notifications that `engine.start()` itself provokes, and
        // cap how many times we'll rebuild so a flapping device can't spin forever.
        guard Date() > configSettleUntil, configRebuilds < 6 else { return }
        configRebuilds += 1
        configSettleUntil = Date().addingTimeInterval(0.75)

        recovering = true
        defer { recovering = false }

        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if engine.isRunning { engine.stop() }

        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.handleConfigurationChange()
            }
            return
        }

        do {
            try startEngine(feeding: continuation, outputFormat: format)
            #if DEBUG
            print("[Scribe] rebuilt audio tap after configuration change (#\(configRebuilds))")
            #endif
        } catch {
            Task { [weak self] in await self?.handleFailure(error) }
        }
    }

    // MARK: Audio engine

    /// Points the current engine's input at the chosen mic (built-in unless the user picked
    /// otherwise). Must run before the input AU is initialised — i.e. on a fresh `engine`.
    @discardableResult
    private func applyInputDevice() -> AudioInputDevice? {
        guard let device = resolvedInput() else {
            inputDeviceName = Self.currentInputName()
            return nil
        }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(device.id)
            inputDeviceName = device.name
            #if DEBUG
            let actual = engine.inputNode.auAudioUnit.deviceID
            print("[Scribe] input device → \(device.name) [asked \(device.id), got \(actual)]")
            #endif
            return device
        } catch {
            inputDeviceName = Self.currentInputName()
            #if DEBUG
            print("[Scribe] setDeviceID(\(device.name)) failed: \(error); using \(inputDeviceName)")
            #endif
            return nil
        }
    }

    private func startEngine(feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
                             outputFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Scribe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The input device isn't ready."])
        }

        let converter: AVAudioConverter? = inputFormat == outputFormat
            ? nil
            : AVAudioConverter(from: inputFormat, to: outputFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let clock = self.clock

        // Explicitly `@Sendable` so the realtime tap thread carries no actor expectations
        // (a main-actor-isolated tap block trips Swift's executor assertion and crashes).
        let block: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            let out: AVAudioPCMBuffer
            if let converter {
                let ratio = outputFormat.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
                guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
                var conversionError: NSError?
                let source = SingleBuffer(buffer)
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if let next = source.take() {
                        status.pointee = .haveData
                        return next
                    }
                    status.pointee = .noDataNow
                    return nil
                }
                guard conversionError == nil, converted.frameLength > 0 else { return }
                out = converted
            } else {
                out = buffer
            }

            Self.updatePeak(from: out, into: clock)
            _ = clock.frames.add(Int64(out.frameLength), ordering: .relaxed)
            continuation.yield(AnalyzerInput(buffer: out))
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: block)
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func teardownEngine() async {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    /// Peak amplitude of a buffer, read straight from its raw bytes so it works whatever the
    /// analyzer's format is (it's frequently interleaved 16-bit int, where the typed
    /// `int16ChannelData` accessor returns nil).
    private nonisolated static func updatePeak(from buffer: AVAudioPCMBuffer, into clock: AudioClock) {
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let audioBuffer = abl.first, let raw = audioBuffer.mData else { return }
        let byteCount = Int(audioBuffer.mDataByteSize)
        guard byteCount > 0 else { return }

        var peak: Float = 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            let count = byteCount / MemoryLayout<Float>.size
            let samples = raw.assumingMemoryBound(to: Float.self)
            var i = 0
            while i < count { peak = max(peak, abs(samples[i])); i += 3 }
        case .pcmFormatInt16:
            let count = byteCount / MemoryLayout<Int16>.size
            let samples = raw.assumingMemoryBound(to: Int16.self)
            var i = 0
            while i < count { peak = max(peak, abs(Float(samples[i])) / 32_767); i += 3 }
        case .pcmFormatInt32:
            let count = byteCount / MemoryLayout<Int32>.size
            let samples = raw.assumingMemoryBound(to: Int32.self)
            var i = 0
            while i < count { peak = max(peak, abs(Float(samples[i])) / 2_147_483_647); i += 3 }
        default:
            return
        }

        let prev = Float(bitPattern: clock.level.load(ordering: .relaxed))
        if peak > prev { clock.level.store(peak.bitPattern, ordering: .relaxed) }
    }

    // MARK: Metering

    private func startMeter() {
        lastLoudAt = .now
        silenceDuration = 0
        meterLevels = Array(repeating: 0, count: meterLevels.count)
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var display: Float = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))   // ~30 fps
                guard let self else { return }
                let peak = min(1, Float(bitPattern: self.clock.level.exchange(0, ordering: .relaxed)))

                // Instant attack, smooth release so the bars glide between tap callbacks
                // instead of strobing to zero.
                display = max(peak, display * 0.78)
                var window = self.meterLevels
                window.removeFirst()
                window.append(display)
                self.meterLevels = window

                self.inputLevel = max(peak, self.inputLevel * 0.85)
                if peak > 0.015 {
                    self.lastLoudAt = .now
                    self.silenceDuration = 0
                } else {
                    self.silenceDuration = Date.now.timeIntervalSince(self.lastLoudAt)
                }
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        meterLevels = Array(repeating: 0, count: meterLevels.count)
    }

    // MARK: System integration

    private func beginActivityAssertion() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Transcribing a live recording"
        )
    }

    private func endActivityAssertion() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    private func observeAudioLifecycle() {
        stopObservers()
        configRebuilds = 0
        configSettleUntil = Date().addingTimeInterval(2)   // let the engine settle after start
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleptAt = Date() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let sleptAt = self.sleptAt {
                    let gap = Date().timeIntervalSince(sleptAt)
                    self.sleptAt = nil
                    if case .running = self.phase, gap > 5 { self.onGap?(gap) }
                }
                guard case .running = self.phase, !self.engine.isRunning else { return }
                self.handleConfigurationChange()
            }
        }
    }

    private func stopObservers() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver); self.sleepObserver = nil }
        sleptAt = nil
    }

    // MARK: Permissions & model

    private func ensurePermissions() async -> Bool {
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

        // Reserve the locale so a concurrent app can't get it evicted mid-lecture.
        if await AssetInventory.reservedLocales.contains(where: { $0.identifier(.bcp47) == wanted }) == false {
            if (try? await AssetInventory.reserve(locale: locale)) == true {
                reservedLocale = locale
            }
        } else {
            reservedLocale = locale
        }

        guard !installed else { return }
        phase = .preparingModel(-1)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, case .preparingModel = self.phase else { return }
                    self.phase = .preparingModel(progress.fractionCompleted)
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
        }
    }

    private func languageName(_ locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func currentInputName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "the microphone"
    }

    private static func message(for error: any Error) -> String {
        if let speech = error as? SFSpeechError {
            switch speech.code {
            case .insufficientResources:
                return "The Mac ran low on resources for transcription. Resume to keep going."
            case .audioDisordered, .unexpectedAudioFormat, .incompatibleAudioFormats:
                return "The audio stream broke up. Resume to keep recording."
            case .assetLocaleNotAllocated, .noModel, .cannotAllocateUnsupportedLocale:
                return "The language model was unloaded. Resume to reload it."
            default:
                break
            }
        }
        return "Recording stopped: \(error.localizedDescription). Resume to continue."
    }
}

/// Lock-free state shared between the realtime audio tap and the main actor.
private final class AudioClock: Sendable {
    /// Monotonic count of analyzer-format frames delivered so far.
    let frames = Atomic<Int64>(0)
    /// Peak sample amplitude since the meter last read it, as a Float bit-pattern.
    let level = Atomic<UInt32>(0)
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

    /// Just the language ("English"), without the region — for tight status lines.
    static func shortName(for locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier,
              let localized = Locale.current.localizedString(forLanguageCode: code)
        else { return name(for: locale) }
        return localized
    }

    /// A reasonable default before the supported list has loaded; the transcriber
    /// resolves this to an actually-supported locale when recording starts.
    static var preferred: Locale {
        Locale.current
    }
}
