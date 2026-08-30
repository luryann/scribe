import SwiftUI

struct FlashcardsView: View {
    @Bindable var document: SessionDocument
    @State private var index = 0
    @State private var showingBack = false

    var body: some View {
        if document.flashcards.isEmpty {
            EmptyHint(
                symbol: "rectangle.on.rectangle.angled",
                title: document.hasTranscript ? "No flashcards yet" : "Nothing to study yet",
                message: document.hasTranscript
                    ? "Tap Generate below and Scribe writes question-and-answer cards from the transcript."
                    : "Record a lecture first, then Scribe can build a deck from it."
            )
        } else {
            let cards = document.flashcards
            let current = cards[min(index, cards.count - 1)]

            VStack(spacing: 10) {
                HStack {
                    Text("\(cards.count) cards · from transcript")
                    Spacer()
                    Text("Card \(min(index, cards.count - 1) + 1) / \(cards.count)")
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
                        showingBack
                            ? Color.scribeBlue.opacity(0.08)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                HStack(spacing: 16) {
                    stepButton("chevron.left") { step(-1) }.disabled(index == 0)
                    Spacer()
                    if cards.count <= 12 {
                        HStack(spacing: 5) {
                            ForEach(cards.indices, id: \.self) { i in
                                Capsule()
                                    .fill(i == index ? Color.scribeBlue : Color.inkFaint.opacity(0.4))
                                    .frame(width: i == index ? 14 : 5, height: 5)
                            }
                        }
                    }
                    Spacer()
                    stepButton("chevron.right") { step(1) }.disabled(index >= cards.count - 1)
                }
            }
            .padding(16)
        }
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
            index = max(0, min(document.flashcards.count - 1, index + delta))
            showingBack = false
        }
    }
}
