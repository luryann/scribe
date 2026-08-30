import SwiftUI

struct TodoView: View {
    @Bindable var document: SessionDocument
    @State private var newTask = ""
    @FocusState private var inputFocused: Bool

    private var trimmedTask: String {
        newTask.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(inputFocused || !trimmedTask.isEmpty ? Color.scribeBlue : Color.inkFaint)

                TextField("Add a task", text: $newTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink)
                    .focused($inputFocused)
                    .onSubmit(add)

                if !trimmedTask.isEmpty {
                    Button(action: add) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.scribeBlue)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, trimmedTask.isEmpty ? 14 : 6)
            .frame(height: 38)
            .background(Color.wellFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(inputFocused ? Color.scribeBlue.opacity(0.55) : Color.white.opacity(0.6),
                                  lineWidth: inputFocused ? 1 : 0.5)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .animation(.easeOut(duration: 0.14), value: trimmedTask.isEmpty)
            .animation(.easeOut(duration: 0.14), value: inputFocused)
        }
    }

    private var doneCount: Int { document.todos.filter(\.isDone).count }

    private func add() {
        let task = trimmedTask
        guard !task.isEmpty else { return }
        document.addTodo(task)
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
