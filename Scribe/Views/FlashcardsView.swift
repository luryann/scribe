import SwiftUI

struct FlashcardsView: View {
    @Bindable var document: SessionDocument
    @State private var studying = false

    var body: some View {
        if document.flashcards.isEmpty {
            EmptyHint(
                symbol: "rectangle.on.rectangle.angled",
                title: document.hasTranscript ? "No flashcards yet" : "Nothing to study yet",
                message: document.hasTranscript
                    ? "Tap Generate below and Scribe writes question-and-answer cards from the transcript."
                    : "Record a lecture first, then Scribe can build a deck from it."
            )
        } else if studying {
            StudySession(cards: document.flashcards) { studying = false }
        } else {
            DeckBrowser(cards: document.flashcards) { studying = true }
        }
    }
}

// MARK: - Browse

private struct DeckBrowser: View {
    let cards: [Flashcard]
    let startStudying: () -> Void

    @State private var index = 0
    @State private var showingBack = false

    var body: some View {
        let current = cards[min(index, cards.count - 1)]

        VStack(spacing: 10) {
            HStack {
                Text("\(cards.count) cards · from transcript")
                Spacer()
                Button(action: startStudying) {
                    Label("Study", systemImage: "graduationcap.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.scribeBlue)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.inkFaint)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showingBack.toggle() }
            } label: {
                Well(padding: 16, cornerRadius: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(showingBack ? "Back — tap to flip" : "Front — tap to reveal")
                            .font(.system(size: 8.5, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(showingBack ? Color.scribeBlue : Color.inkFaint)
                        Text(showingBack ? current.back : current.front)
                            .font(showingBack ? .reading(12.5) : .system(size: 13.5, weight: .semibold))
                            .foregroundStyle(showingBack ? Color.inkSoft : Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .background(
                    showingBack ? Color.scribeBlue.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                stepButton("chevron.left") { step(-1) }.disabled(index == 0)
                Spacer()
                Text("Card \(min(index, cards.count - 1) + 1) / \(cards.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.inkFaint)
                Spacer()
                stepButton("chevron.right") { step(1) }.disabled(index >= cards.count - 1)
            }
        }
        .padding(16)
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.inkSoft)
                .frame(width: 26, height: 26)
                .background(Color.wellFill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            index = max(0, min(cards.count - 1, index + delta))
            showingBack = false
        }
    }
}

// MARK: - Study

private struct StudySession: View {
    let cards: [Flashcard]
    let finish: () -> Void

    @State private var queue: [Flashcard] = []
    @State private var showingBack = false
    @State private var reviewed = 0
    @State private var missed = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: finish) {
                    Label("Done", systemImage: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.inkFaint)
                Spacer()
                Text("\(queue.count) left · \(reviewed) reviewed")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.inkFaint)
            }

            if let current = queue.first {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showingBack.toggle() }
                } label: {
                    Well(padding: 16, cornerRadius: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(showingBack ? "Answer" : "Question — tap to reveal")
                                .font(.system(size: 8.5, weight: .bold))
                                .textCase(.uppercase)
                                .foregroundStyle(showingBack ? Color.scribeBlue : Color.inkFaint)
                            Text(showingBack ? current.back : current.front)
                                .font(showingBack ? .reading(12.5) : .system(size: 13.5, weight: .semibold))
                                .foregroundStyle(showingBack ? Color.inkSoft : Color.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .background(
                        showingBack ? Color.scribeBlue.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if showingBack {
                    HStack(spacing: 10) {
                        gradeButton("Again", color: .scribeRed) { grade(correct: false) }
                        gradeButton("Got it", color: .scribeBlue) { grade(correct: true) }
                    }
                } else {
                    Text("Recall the answer, then tap the card")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.inkFaint)
                        .frame(height: 34)
                }
            } else {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.scribeBlue)
                    Text("Deck complete")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                    Text("\(reviewed) cards · \(missed) needed another look")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkFaint)
                    Button("Study again") { start() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
                Spacer()
            }
        }
        .padding(16)
        .onAppear { if queue.isEmpty { start() } }
    }

    private func gradeButton(_ title: String, color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    private func start() {
        queue = cards.shuffled()
        showingBack = false
        reviewed = 0
        missed = 0
    }

    private func grade(correct: Bool) {
        guard !queue.isEmpty else { return }
        let card = queue.removeFirst()
        reviewed += 1
        if !correct {
            missed += 1
            queue.append(card)   // see it again at the end
        }
        withAnimation(.easeOut(duration: 0.12)) { showingBack = false }
    }
}
