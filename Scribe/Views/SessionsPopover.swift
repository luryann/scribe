import SwiftUI

struct SessionsPopover: View {
    @Environment(AppModel.self) private var app
    @State private var refs: [SessionRef] = []
    @State private var hovered: SessionRef.ID?
    @State private var pendingDelete: SessionRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    app.newSession()
                    app.showingSessions = false
                } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.scribeBlue)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            Group {
                if refs.isEmpty {
                    Text("No saved sessions yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 14)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(refs) { ref in
                                row(ref)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            .frame(height: 380)
        }
        .frame(width: 268)
        .onAppear { refs = app.library.sessions() }
        .confirmationDialog(
            "Delete “\(pendingDelete?.meta.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { ref in
            Button("Move to Trash", role: .destructive) {
                app.delete(ref)
                refs = app.library.sessions()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The session folder moves to the Trash. You can put it back from there.")
        }
    }

    private func row(_ ref: SessionRef) -> some View {
        let isCurrent = ref.id == app.document?.meta.id
        let isHovered = hovered == ref.id

        return HStack(spacing: 8) {
            Button {
                app.open(ref)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ref.meta.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(ref.meta.createdAt, format: .dateTime.month().day().hour().minute())
                        if ref.meta.duration > 1 {
                            Text("·")
                            Text(timecode(ref.meta.duration)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                Button {
                    pendingDelete = ref
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete session")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.scribeBlue.opacity(0.12) : (isHovered ? Color.black.opacity(0.05) : Color.clear))
        )
        .onHover { hovered = $0 ? ref.id : (hovered == ref.id ? nil : hovered) }
        .contextMenu {
            Button("Open") { app.open(ref) }
            Button("Reveal in Finder") { app.library.reveal(ref.store) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = ref }
        }
    }
}
