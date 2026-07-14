import AppKit
import RepoDeckKit
import SwiftUI

/// Pill showing the current branch's open PR: its number, a CI status dot,
/// and a draft indicator when applicable. Tapping opens the PR on
/// github.com. Rendered by `SyncControlsView` only when `vm.prInfo != nil`
/// — this view itself has no "no PR"/error state to render, which keeps
/// the feature's optional-integration contract (nothing shows when `gh` is
/// absent, unauthenticated, or there's simply no open PR) entirely in the
/// caller's hands.
struct PRBadgeView: View {
    @Environment(\.theme) private var theme
    let info: PullRequestInfo

    var body: some View {
        Button {
            guard let url = URL(string: info.url) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 4) {
                statusDot
                Text("PR #\(info.number)")
                    .font(theme.caption)
                if info.isDraft {
                    Text("Draft")
                        .font(theme.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().strokeBorder(.secondary.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
        .help(info.title)
    }

    /// Green passing / red failing / amber pending / hollow (stroke-only)
    /// none — `.none` means the PR has no checks configured at all, which
    /// is visually distinct from every check having actually passed.
    @ViewBuilder
    private var statusDot: some View {
        switch info.checks {
        case .passing:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .failing:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        case .pending:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        case .none:
            Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 8, height: 8)
        }
    }
}
