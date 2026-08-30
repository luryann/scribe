import SwiftUI

struct TabBar: View {
    @Binding var selection: MainTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? Color.ink : Color.inkFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}
