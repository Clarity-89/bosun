import SwiftUI

/// The cheat sheet, from the same table the keys use.
struct ShortcutsView: View {
    static let windowID = "shortcuts"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("In the list")
                    Text("Anywhere")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(Shortcut.Section.allCases, id: \.self) { section in
                    Text(section.rawValue)
                        .font(.headline)
                        .padding(.top, 8)
                    ForEach(Shortcut.allCases.filter { $0.section == section }, id: \.self) { action in
                        GridRow {
                            Text(action.title)
                            Text(action.listKeyLabel)
                            Text(action.menuLabel)
                        }
                    }
                }
            }
            Text("List keys work while the session list has focus; \(Shortcut.focusSidebar.menuLabel) puts it there. The others work anywhere in the window, the terminal included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .fixedSize()
    }
}
