import SwiftUI

struct SummaryView: View {
    @Bindable var document: SessionDocument
    @Environment(AppModel.self) private var app

    private var isLocal: Bool { app.intelligence.provider == .apple }

    var body: some View {
        if document.summary.isEmpty {
            EmptyHint(
                symbol: "sparkles",
                title: document.hasTranscript ? "No summary yet" : "Nothing to summarize yet",
                message: document.hasTranscript
                    ? "Tap Summarize below and Scribe will condense the whole lecture\(isLocal ? " on-device" : " with Google Gemini")."
                    : "Record a lecture first, then Scribe can summarize it."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label(isLocal ? "On-device summary" : "Gemini summary", systemImage: "sparkles")
                        .font(.system(size: 9.5, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.scribeBlue)
                        .padding(.bottom, 2)

                    Text(rendered)
                        .font(.reading(13))
                        .foregroundStyle(Color.inkSoft)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(isLocal ? "Generated locally with Apple Intelligence" : "Generated with Google Gemini")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.inkFaint)
                        .padding(.top, 6)
                }
                .padding(16)
            }
        }
    }

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: document.summary,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(document.summary)
    }
}
