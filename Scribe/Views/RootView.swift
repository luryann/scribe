import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            GlassBackground()

            if app.library.needsFolder {
                FolderGate()
            } else if let document = app.document {
                SessionPanel(document: document)
                    .id(document.meta.id)
            } else {
                Color.clear.onAppear { app.bootstrap() }
            }
        }
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 460,
               minHeight: 420, idealHeight: 468, maxHeight: 820)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .tint(Color.scribeBlue)
        .alert("Something went wrong",
               isPresented: Binding(
                get: { app.library.errorMessage != nil },
                set: { if !$0 { app.library.errorMessage = nil } }
               ),
               presenting: app.library.errorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }
}

// MARK: - Folder gate

private struct FolderGate: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.inkFaint)
            Text("Choose where Scribe saves your work")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text("Transcripts, notes, flashcards and to-dos are written as plain files in a folder you pick.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.inkSoft.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
            Button("Choose Folder…") {
                app.library.chooseFolder()
                app.bootstrap()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(28)
    }
}

// MARK: - Session panel

private struct SessionPanel: View {
    @Bindable var document: SessionDocument

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(document: document)
            RecordRow(document: document)
            TabBar(selection: $document.tab)
                .padding(.horizontal, 12)
                .padding(.top, 2)
            Divider().opacity(0.4).padding(.top, 8)

            Group {
                switch document.tab {
                case .live:    LiveView(document: document)
                case .summary: SummaryView(document: document)
                case .notes:   NotesView(document: document)
                case .cards:   FlashcardsView(document: document)
                case .todos:   TodoView(document: document)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FooterBar(document: document)
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @Bindable var document: SessionDocument
    @Environment(AppModel.self) private var app
    @FocusState private var titleFocused: Bool

    var body: some View {
        @Bindable var app = app
        return HStack(spacing: 8) {
            Spacer(minLength: 72)  // clear the traffic lights

            TextField("Session title", text: $document.meta.title)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(document.meta.title == SessionDocument.defaultTitle ? Color.inkFaint : Color.ink)
                .focused($titleFocused)
                .onSubmit { titleFocused = false; document.scheduleSave() }
                .onChange(of: titleFocused) { _, focused in if !focused { document.scheduleSave() } }

            Spacer(minLength: 0)

            MicMenu(document: document)

            if !app.languages.isEmpty {
                Menu {
                    ForEach(app.languages, id: \.identifier) { locale in
                        Button {
                            document.locale = locale
                        } label: {
                            if locale.identifier == document.locale.identifier {
                                Label(SpeechLanguages.name(for: locale), systemImage: "checkmark")
                            } else {
                                Text(SpeechLanguages.name(for: locale))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.inkFaint)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(document.isRecording)
                .help("Transcription language")
            }

            Button {
                app.showingSessions.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.inkFaint)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $app.showingSessions, arrowEdge: .bottom) {
                SessionsPopover()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(height: 34)
    }
}

// MARK: - Microphone picker

private struct MicMenu: View {
    @Bindable var document: SessionDocument
    @Environment(AppModel.self) private var app

    private var selectedUID: String? { document.transcriber.preferredInputUID }

    var body: some View {
        Menu {
            Button {
                document.transcriber.preferredInputUID = nil
            } label: {
                row("Automatic (built-in mic)", selected: selectedUID == nil)
            }

            if !app.inputDevices.isEmpty {
                Divider()
                ForEach(app.inputDevices) { device in
                    Button {
                        document.transcriber.preferredInputUID = device.uid
                    } label: {
                        row(device.isBluetooth ? "\(device.name) — Bluetooth" : device.name,
                            selected: selectedUID == device.uid)
                    }
                }
            }
        } label: {
            Image(systemName: selectedUID == nil ? "mic" : "mic.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.inkFaint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(document.isRecording)
        .help("Microphone")
    }

    @ViewBuilder
    private func row(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

// MARK: - Record row

private struct RecordRow: View {
    @Bindable var document: SessionDocument
    @Environment(AppModel.self) private var app

    private var micIsDead: Bool {
        document.transcriber.isRunning && document.transcriber.silenceDuration > 45
    }

    private var buttonState: RecordButton.Mode {
        if document.isInterrupted { return .idle }
        if document.isPaused { return .paused }
        // `isActive` (not `isRunning`) so the button reads as "stop" while permission is being
        // requested or the model is downloading — that's exactly what tapping it does.
        return document.transcriber.isActive ? .recording : .idle
    }

    var body: some View {
        HStack(spacing: 12) {
            RecordButton(state: buttonState) {
                Task { await document.toggleRecording() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(timecode(document.elapsed))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(document.isRecording ? Color.ink : Color.inkFaint)

                HStack(spacing: 5) {
                    if document.transcriber.isRunning && !micIsDead {
                        Circle().fill(Color.scribeRed).frame(width: 6, height: 6)
                    }
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(micIsDead ? Color.scribeRed : Color.inkSoft.opacity(0.8))
                        .lineLimit(statusIsMessage ? 2 : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: statusIsMessage)
                }
            }

            Spacer(minLength: 8)

            controls
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.16), value: document.isPaused)
        .task(id: document.isRecording) {
            if !document.isRecording {
                app.refreshInputDevices()
                document.transcriber.refreshInputDevice()
            }
        }
    }

    /// Long, wrapping copy (errors, warnings) vs. a short one-line status.
    private var statusIsMessage: Bool {
        if micIsDead { return true }
        switch document.transcriber.phase {
        case .interrupted, .unavailable: return true
        default: return false
        }
    }

    @ViewBuilder
    private var controls: some View {
        if document.isInterrupted {
            Button("Resume") { Task { await document.resumeRecording() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if document.isPaused {
            Button {
                Task { await document.resumeRecording() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    Text("Resume").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(Color.scribeBlue))
            }
            .buttonStyle(.plain)
            .help("Resume recording")
        } else if document.transcriber.isRunning {
            HStack(spacing: 10) {
                LevelMeter(transcriber: document.transcriber)
                TransportCapsule(
                    bookmark: { document.addBookmark() },
                    pause: { document.pauseRecording() }
                )
            }
        }
    }

    private var statusLine: String {
        if micIsDead {
            return "No sound from \(document.transcriber.inputDeviceName) — check it's not muted."
        }
        let language = SpeechLanguages.shortName(for: document.locale)
        switch document.transcriber.phase {
        case .idle:
            return document.hasTranscript
                ? "Recorded \(RelativeDateTimeFormatter().localizedString(for: document.meta.createdAt, relativeTo: .now))"
                : "Ready · \(language) · \(document.transcriber.inputDeviceName)"
        case .requestingPermission:
            return "Waiting for permission…"
        case .preparingModel(let progress):
            return progress >= 0
                ? "Preparing the \(language) model… \(Int(progress * 100))%"
                : "Preparing the \(language) model…"
        case .running:
            return "Recording"
        case .paused:
            return "Paused · \(timecode(document.elapsed)) captured"
        case .interrupted(let why):
            return why
        case .unavailable(let why):
            return why
        }
    }
}

/// The two live-recording controls as one glass segment — matched to the panel's `Well`
/// vocabulary so they read as a deliberate unit, not two loose circles.
private struct TransportCapsule: View {
    let bookmark: () -> Void
    let pause: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SegmentButton(symbol: "bookmark", help: "Bookmark this moment (⌘B)", action: bookmark)
            Rectangle()
                .fill(Color.ink.opacity(0.10))
                .frame(width: 1, height: 15)
            SegmentButton(symbol: "pause.fill", help: "Pause recording", action: pause)
        }
        .frame(height: 26)
        .background(Color.wellFill)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.65), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.06), radius: 2.5, y: 1)
    }
}

private struct SegmentButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(hovering ? Color.ink : Color.inkSoft)
                .frame(width: 32, height: 26)
                .background(hovering ? Color.white.opacity(0.55) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct RecordButton: View {
    enum Mode { case idle, recording, paused }

    let state: Mode
    let action: () -> Void
    @State private var hovering = false

    private var fill: Color {
        switch state {
        case .idle:      Color.white
        case .recording: Color.scribeRed
        case .paused:    Color.scribeRed.opacity(0.4)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                    .overlay(Circle().strokeBorder(Color.black.opacity(state == .idle ? 0.08 : 0), lineWidth: 0.5))
                    .shadow(color: state == .recording ? Color.scribeRed.opacity(0.5) : Color.black.opacity(0.18),
                            radius: state == .recording ? 8 : 4, y: state == .recording ? 3 : 2)
                    .frame(width: 42, height: 42)

                switch state {
                case .idle:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.ink)
                case .recording:
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                case .paused:
                    Image(systemName: "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.white)
                }
            }
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(state == .idle ? "Start recording" : "Stop recording")
    }
}

/// A live rolling meter: each bar is one recent ~33 ms peak reading from the mic, newest on
/// the right. Height and redness both track the actual sound, so silence sits nearly flat and
/// faint (backing up the dead-mic warning) and speech ripples through it in real time.
private struct LevelMeter: View {
    let transcriber: Transcriber

    var body: some View {
        let levels = transcriber.meterLevels
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(levels.indices, id: \.self) { index in
                let shaped = Self.shape(levels[index])
                Capsule()
                    .fill(Color.scribeRed.opacity(0.22 + 0.65 * Double(shaped)))
                    .frame(width: 2, height: max(2.5, CGFloat(shaped) * 22))
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.045), value: levels)
        .accessibilityHidden(true)
    }

    /// Perceptual curve — boosts quiet speech so the meter clearly reacts without clipping.
    private static func shape(_ value: Float) -> Float {
        min(1, pow(max(0, value), 0.45) * 1.3)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Bindable var document: SessionDocument
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            if let trouble = app.library.saveTrouble {
                Text(trouble)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scribeRed)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            ForEach(document.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if let error = document.aiError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scribeRed)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else if !app.intelligence.isAvailable, let reason = app.intelligence.unavailableReason, needsAI {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.inkFaint)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if document.isRunningJob {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busyLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.inkSoft)
                    Spacer(minLength: 0)
                    Button("Cancel") { document.cancelJob() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.scribeBlue)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .padding(.horizontal, 12)
                .background(Color.scribeBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                FooterActionButton(
                    title: config.title,
                    systemImage: config.symbol,
                    isBusy: false,
                    isEnabled: isEnabled,
                    action: config.run
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(Divider().opacity(0.4), alignment: .top)
    }

    private var needsAI: Bool { config.job != nil }

    private var busyLabel: String {
        let base: String
        switch document.runningJob {
        case .summary: base = "Summarizing"
        case .cards:   base = "Writing cards"
        case .todos:   base = "Finding to-dos"
        case .notes:   base = "Polishing notes"
        default:       base = "Working"
        }
        if let progress = document.jobProgress {
            return "\(base)… \(progress.step)/\(progress.total)"
        }
        return "\(base)…"
    }

    private var isEnabled: Bool {
        guard let job = config.job else { return true }
        if !app.intelligence.isAvailable { return false }
        if document.runningJob != nil { return false }
        switch job {
        case .notes:  return document.notes.trimmingCharacters(in: .whitespacesAndNewlines).count > 20
        default:      return document.hasTranscript
        }
    }

    private struct Config {
        var title: String
        var symbol: String
        var job: AIJob?
        var run: () -> Void
    }

    private var config: Config {
        switch document.tab {
        case .live:
            Config(title: "Summarize this lecture", symbol: "sparkles", job: .summary) {
                Task { await document.summarize(); document.tab = .summary }
            }
        case .summary:
            Config(title: document.summary.isEmpty ? "Summarize this lecture" : "Regenerate summary",
                   symbol: document.summary.isEmpty ? "sparkles" : "arrow.clockwise", job: .summary) {
                Task { await document.summarize() }
            }
        case .notes:
            Config(title: "Polish notes with AI", symbol: "sparkles", job: .notes) {
                Task { await document.polishNotes() }
            }
        case .cards:
            Config(title: document.flashcards.isEmpty ? "Generate cards from transcript" : "Regenerate cards",
                   symbol: "sparkles", job: .cards) {
                Task { await document.generateFlashcards() }
            }
        case .todos:
            Config(title: document.todos.isEmpty ? "Auto-create to-dos from transcript" : "Refresh to-dos from transcript",
                   symbol: "sparkles", job: .todos) {
                Task { await document.generateTodos() }
            }
        }
    }
}
