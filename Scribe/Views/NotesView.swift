import SwiftUI

struct NotesView: View {
    @Bindable var document: SessionDocument
    @FocusState private var editing: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $document.notes)
                .font(.reading(13))
                .foregroundStyle(Color.inkSoft)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($editing)
                .padding(10)
                .onChange(of: document.notes) { document.scheduleSave() }

            if document.notes.isEmpty && !editing {
                Text("Type your own notes here. They save as you go, right next to the transcript.")
                    .font(.reading(13))
                    .foregroundStyle(Color.inkFaint)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
    }
}
