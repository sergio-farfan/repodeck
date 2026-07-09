import SwiftUI

/// Small monospaced badge for a git status letter (or unmerged pair, e.g.
/// "UU"), colored to roughly match VS Code's Source Control decorations.
struct StatusLetterBadge: View {
    @Environment(\.theme) private var theme
    let letter: String

    var body: some View {
        Text(letter)
            .font(theme.mono(11, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 22)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        if letter.count > 1 {
            // Unmerged combos: UU, AA, DD, AU, UA, DU, UD.
            return .red
        }
        switch letter {
        case "M": return .orange
        case "A": return .green
        case "D": return .red
        case "R", "C": return .blue
        case "T": return .orange
        case "U": return .green
        default: return .gray
        }
    }
}
