import RepoDeckKit
import SwiftUI

/// Stashes section rendered at the bottom of `ChangesListView`'s `List`.
/// Each row shows the stash subject (truncated middle) and, when parseable,
/// a relative-date secondary line. Context menu offers Apply/Pop/Drop; Drop
/// is confirmed via `.confirmationDialog` since it discards the stash.
struct StashSection: View {
    let vm: RepoViewModel

    /// The stash a Drop context-menu tap is confirming, if any — drives the
    /// `.confirmationDialog`. Kept as the entry itself (not just its index)
    /// so the dialog's title/message can't drift if `vm.stashes` refreshes
    /// mid-confirmation.
    @State private var pendingDrop: StashEntry?

    var body: some View {
        Section("Stashes (\(vm.stashes.count))") {
            ForEach(vm.stashes) { stash in
                StashRow(stash: stash, vm: vm, pendingDrop: $pendingDrop)
            }
        }
        .confirmationDialog(
            "Drop this stash? This cannot be undone.",
            isPresented: Binding(
                get: { pendingDrop != nil },
                set: { if !$0 { pendingDrop = nil } }
            ),
            presenting: pendingDrop
        ) { stash in
            Button("Drop", role: .destructive) {
                Task { await vm.stashDrop(stash.index) }
            }
        }
    }
}

/// A single stash row: `tray` glyph, subject (truncated middle), relative
/// date secondary line. Mirrors `FileChangeRow`'s idiom.
private struct StashRow: View {
    @Environment(\.theme) private var theme
    let stash: StashEntry
    let vm: RepoViewModel
    @Binding var pendingDrop: StashEntry?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(stash.subject)
                    .font(theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = stash.date {
                    Text(date, format: .relative(presentation: .named))
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Apply") {
                Task { await vm.stashApply(stash.index) }
            }
            Button("Pop") {
                Task { await vm.stashPop(stash.index) }
            }
            Button("Drop", role: .destructive) {
                pendingDrop = stash
            }
        }
    }
}
