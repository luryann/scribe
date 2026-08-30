import SwiftUI

struct TodoView: View {
    @Bindable var document: SessionDocument
    @State private var newTask = ""

    var body: some View {
        VStack(spacing: 0) {
            if document.todos.isEmpty {
                EmptyHint(
                    symbol: "checklist",
                    title: document.hasTranscript ? "No to-dos yet" : "Nothing to do yet",
                    message: document.hasTranscript
                        ? "Tap the button below and Scribe pulls action items out of what was said."
                        : "Record a lecture first, then Scribe can find the action items in it."
                )
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        HStack {
                            Text("\(doneCount) of \(document.todos.count) done").foregroundStyle(Color.ink)
                            Spacer()
                            Text("Auto-extracted").foregroundStyle(Color.inkFaint)
                        }
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 2)
                        .padding(.bottom, 2)

                        ForEach($document.todos) { $item in
                            TodoRow(item: $item) {
                                document.scheduleSave()
                            } jump: {
                                if let time = item.sourceTime { document.jump(to: time) }
                            }
                        }
                    }
                    .padding(14)
                }
            }

            HStack(spacing: 8) {
                TextField("Add a task", text: $newTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(newTask.isEmpty ? Color.inkFaint : Color.scribeBlue)
                    .disabled(newTask.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.wellFill)
            .overlay(Divider().opacity(0.4), alignment: .top)
        }
    }

    private var doneCount: Int { document.todos.filter(\.isDone).count }

    private func add() {
        document.addTodo(newTask)
        newTask = ""
    }
}

private struct TodoRow: View {
    @Binding var item: TodoItem
    let changed: () -> Void
    let jump: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                item.isDone.toggle()
                changed()
            } label: {
                Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isDone ? Color.scribeBlue : Color.inkFaint)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? Color.inkFaint : Color.ink)
                    .strikethrough(item.isDone)
                if let due = item.dueHint {
                    Text(due)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.orange)
                } else if let quote = item.sourceQuote {
                    Text("“\(quote)”")
                        .font(.reading(9.5))
                        .italic()
                        .foregroundStyle(Color.inkFaint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let time = item.sourceTime {
                Button(action: jump) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right")
                        Text(timecode(time)).monospacedDigit()
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.scribeBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Jump to where this was said")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5))
    }
}
