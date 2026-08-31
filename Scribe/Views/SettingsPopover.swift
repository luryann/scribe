import SwiftUI

/// Hidden provider-settings panel, opened by Option-clicking the Sessions button. Lets the
/// user route Scribe's AI passes through Google Gemini instead of the on-device Apple model,
/// and back. Styled to match `SessionsPopover`.
struct SettingsPopover: View {
    @Environment(AppModel.self) private var app

    @State private var keyDraft = ""
    @State private var models: [String] = []
    @State private var verifying = false
    @State private var verifyError: String?
    @State private var verified = false

    private var service: IntelligenceService { app.intelligence }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI Provider")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AIProvider.allCases) { provider in
                        providerRow(provider)
                    }

                    if service.provider == .gemini {
                        geminiConfig
                            .padding(.top, 4)
                    }

                    Text(service.provider == .apple
                        ? "Apple Intelligence runs entirely on your Mac. Nothing leaves the device."
                        : "Gemini sends the lecture transcript to Google's servers to generate results. Switch back to Apple Intelligence to stay offline.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                .padding(12)
            }
            .frame(height: 360)
        }
        .frame(width: 300)
        .onAppear {
            keyDraft = service.geminiKey ?? ""
            verified = service.hasGeminiKey
            if service.hasGeminiKey, models.isEmpty { verify(silent: true) }
        }
    }

    // MARK: Provider rows

    private func providerRow(_ provider: AIProvider) -> some View {
        let isCurrent = service.provider == provider

        return Button {
            service.provider = provider
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrent ? Color.scribeBlue : Color.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(provider.blurb)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent ? Color.scribeBlue.opacity(0.12) : Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Gemini config

    @ViewBuilder
    private var geminiConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API KEY")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(Color.inkFaint)

            HStack(spacing: 6) {
                SecureField("AIza…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .onChange(of: keyDraft) { _, _ in verified = false; verifyError = nil }

                Button(verifying ? "…" : "Verify") { verify(silent: false) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(verifying || keyDraft.trimmingCharacters(in: .whitespaces).count < 10)
            }

            if let verifyError {
                Text(verifyError)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.scribeRed)
                    .fixedSize(horizontal: false, vertical: true)
            } else if verified, !models.isEmpty {
                HStack(spacing: 6) {
                    Text("MODEL")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.inkFaint)
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button {
                                service.geminiModel = model
                            } label: {
                                if model == service.geminiModel {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    } label: {
                        Text(service.geminiModel.isEmpty ? "Choose…" : service.geminiModel)
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if service.isAvailable {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Actions

    private func verify(silent: Bool) {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 10 else { return }
        verifying = true
        if !silent { verifyError = nil }

        Task {
            do {
                let list = try await GeminiBackend.listModels(key: key)
                models = list.sorted()
                service.setGeminiKey(key)
                if service.geminiModel.isEmpty || !list.contains(service.geminiModel) {
                    service.geminiModel = Self.preferredModel(from: list) ?? list.first ?? ""
                }
                verified = true
                verifyError = nil
            } catch is CancellationError {
                // ignore
            } catch {
                verified = false
                if !silent {
                    verifyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            verifying = false
        }
    }

    /// Best default from what a key exposes. Extraction (to-dos, flashcards) needs a capable
    /// model, so never auto-pick a "lite" / "8b" tier — the user can still choose one manually.
    static func preferredModel(from list: [String]) -> String? {
        let usable = list.filter { name in
            let n = name.lowercased()
            return n.contains("gemini")
                && !["lite", "-8b", "tts", "embedding", "image", "vision", "aqa", "learnlm"]
                    .contains(where: n.contains)
        }
        func pick(_ predicate: (String) -> Bool) -> String? {
            usable.filter(predicate).max { versionScore($0) < versionScore($1) }
        }
        return pick { $0.contains("flash") && !$0.contains("preview") && !$0.contains("exp") }
            ?? pick { $0.contains("flash") }
            ?? pick { $0.contains("pro") && !$0.contains("preview") && !$0.contains("exp") }
            ?? pick { $0.contains("pro") }
            ?? usable.first
            ?? list.first { !$0.lowercased().contains("embedding") }
    }

    /// Orders model ids newest-first-ish: "-latest" wins, then higher version numbers.
    private static func versionScore(_ name: String) -> Double {
        if name.contains("latest") { return 999 }
        let digits = name.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .compactMap { Double($0) }
        return digits.max() ?? 0
    }
}
