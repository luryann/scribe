import SwiftUI

struct LiveView: View {
    @Bindable var document: SessionDocument
    @State private var flash: TranscriptSegment.ID?

    var body: some View {
        if document.segments.isEmpty && document.volatile.isEmpty && !document.transcriber.isRunning {
            EmptyHint(
                symbol: "waveform",
                title: "Ready when you are",
                message: "Press record to start a live transcript. Everything is transcribed on-device and saved as you go."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(TranscriptLayout.paragraphs(from: document.segments)) { paragraph in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(paragraph.marker)
                                    .font(.system(size: 10, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.inkFaint.opacity(0.8))
                                Text(paragraph.text)
                                    .font(.reading(13))
                                    .foregroundStyle(Color.inkSoft)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.scribeBlue.opacity(flash == paragraph.id ? 0.14 : 0))
                            )
                            .id(paragraph.id)
                        }

                        if !document.volatile.isEmpty {
                            Text(document.volatile)
                                .font(.reading(13))
                                .italic()
                                .foregroundStyle(Color.inkFaint)
                                .padding(.horizontal, 6)
                                .id(volatileAnchor)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: document.segments.count) {
                    withAnimation(.easeOut(duration: 0.2)) { scrollToEnd(proxy) }
                }
                .onChange(of: document.volatile) {
                    scrollToEnd(proxy)
                }
                .onChange(of: document.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                    flash = target
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation { flash = nil }
                        document.scrollTarget = nil
                    }
                }
            }
        }
    }

    private let volatileAnchor = "scribe.volatile"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if !document.volatile.isEmpty {
            proxy.scrollTo(volatileAnchor, anchor: .bottom)
        } else if let last = TranscriptLayout.paragraphs(from: document.segments).last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}
