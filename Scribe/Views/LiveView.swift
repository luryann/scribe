import SwiftUI

struct LiveView: View {
    @Bindable var document: SessionDocument
    @State private var flash: TranscriptParagraph.ID?
    @State private var following = true

    var body: some View {
        if document.paragraphs.isEmpty && document.volatile.isEmpty && !document.transcriber.isRunning {
            EmptyHint(
                symbol: "waveform",
                title: "Ready when you are",
                message: "Press record to start a live transcript. Everything is transcribed on-device and saved as you go."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(document.paragraphs) { paragraph in
                            ParagraphRow(
                                paragraph: paragraph,
                                bookmarked: hasBookmark(in: paragraph),
                                flashing: flash == paragraph.id
                            )
                            .id(paragraph.id)
                        }

                        VolatileLine(document: document)
                            .id(volatileAnchor)
                    }
                    .padding(16)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 32
                } action: { _, nearBottom in
                    following = nearBottom
                }
                .overlay(alignment: .bottom) {
                    if !following && document.transcriber.isRunning {
                        Button {
                            following = true
                            withAnimation(.easeOut(duration: 0.2)) { scrollToEnd(proxy) }
                        } label: {
                            Label("Jump to live", systemImage: "arrow.down")
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.scribeBlue, in: Capsule())
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: following)
                .onChange(of: document.paragraphs.count) {
                    guard following else { return }
                    withAnimation(.easeOut(duration: 0.2)) { scrollToEnd(proxy) }
                }
                .onChange(of: document.volatile.isEmpty) {
                    guard following else { return }
                    Task { @MainActor in scrollToEnd(proxy) }
                }
                .onChange(of: document.scrollTarget) { _, _ in handleScrollTarget(proxy) }
                .onAppear { handleScrollTarget(proxy) }
            }
        }
    }

    /// Scrolls to and flashes a "jump to source" target. Runs both on change *and* on appear,
    /// because a jump from another tab sets `scrollTarget` before this view exists, and
    /// `onChange` never fires for a value that was already set when the view mounted.
    private func handleScrollTarget(_ proxy: ScrollViewProxy) {
        guard let target = document.scrollTarget else { return }
        following = false
        Task { @MainActor in
            // Give the list a beat to lay out if we've only just switched to this tab.
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
            flash = target
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { if flash == target { flash = nil } }
            if document.scrollTarget == target { document.scrollTarget = nil }
        }
    }

    private let volatileAnchor = "scribe.volatile"

    private func hasBookmark(in paragraph: TranscriptParagraph) -> Bool {
        let end = paragraph.start + 18
        return document.bookmarks.contains { $0.time >= paragraph.start - 1 && $0.time <= end }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if !document.volatile.isEmpty {
            proxy.scrollTo(volatileAnchor, anchor: .bottom)
        } else if let last = document.paragraphs.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

private struct ParagraphRow: View {
    let paragraph: TranscriptParagraph
    let bookmarked: Bool
    let flashing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(paragraph.marker)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.inkFaint.opacity(0.8))
                if bookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.scribeBlue)
                }
            }
            Text(paragraph.text)
                .font(.reading(13))
                .foregroundStyle(Color.inkSoft)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.scribeBlue.opacity(flashing ? 0.14 : 0))
        )
    }
}

/// Isolated so the several-times-a-second volatile updates only invalidate this line,
/// not the whole transcript list.
private struct VolatileLine: View {
    @Bindable var document: SessionDocument

    var body: some View {
        if document.volatile.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            Text(document.volatile)
                .font(.reading(13))
                .italic()
                .foregroundStyle(Color.inkFaint)
                .padding(.horizontal, 6)
        }
    }
}
