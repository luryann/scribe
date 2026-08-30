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

// MARK: - Record row

private struct RecordRow: View {
    @Bindable var document: SessionDocument

    var body: some View {
        HStack(spacing: 12) {
            RecordButton(isRecording: document.isRecording) {
                Task { await document.toggleRecording() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(timecode(document.elapsed))
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(document.isRecording ? Color.ink : Color.inkFaint)

                HStack(spacing: 5) {
                    if document.transcriber.isRunning {
                        Circle().fill(Color.scribeRed).frame(width: 6, height: 6)
                    }
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.inkSoft.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if document.transcriber.isRunning {
                WaveBars()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var statusLine: String {
        switch document.transcriber.phase {
        case .idle:
            return document.hasTranscript
                ? "Recorded \(RelativeDateTimeFormatter().localizedString(for: document.meta.createdAt, relativeTo: .now))"
                : "Ready · \(SpeechLanguages.name(for: document.locale))"
        case .requestingPermission: return "Waiting for permission…"
        case .preparingModel:       return "Preparing the \(SpeechLanguages.name(for: document.locale)) model…"
        case .running:              return "Recording · \(SpeechLanguages.name(for: document.locale))"
        case .unavailable(let why): return why
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.scribeRed : Color.white)
                    .overlay(
                        Circle().strokeBorder(Color.black.opacity(isRecording ? 0 : 0.08), lineWidth: 0.5)
                    )
                    .shadow(color: isRecording ? Color.scribeRed.opacity(0.5) : Color.black.opacity(0.18),
                            radius: isRecording ? 8 : 4, y: isRecording ? 3 : 2)
                    .frame(width: 42, height: 42)

                if isRecording {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.ink)
                }
            }
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct WaveBars: View {
    @State private var animating = false
    private let heights: [CGFloat] = [0.4, 0.8, 0.55, 1.0, 0.35, 0.7, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.inkSoft.opacity(0.5))
                    .frame(width: 2.5, height: 26 * heights[index])
                    .scaleEffect(y: animating ? 1 : 0.4, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.5 + heights[index] * 0.3)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.08),
                        value: animating
                    )
            }
        }
        .frame(height: 26)
        .onAppear { animating = true }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Bindable var document: SessionDocument
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
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

            FooterActionButton(
                title: config.title,
                systemImage: config.symbol,
                isBusy: document.runningJob == config.job,
                isEnabled: isEnabled,
                action: config.run
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .overlay(Divider().opacity(0.4), alignment: .top)
    }

    private var needsAI: Bool { config.job != nil }

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
