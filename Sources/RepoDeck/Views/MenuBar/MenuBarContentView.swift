import AppKit
import SwiftUI

/// Compact `MenuBarExtra` dashboard (see `RepoDeckApp`, which gives the
/// extra `.menuBarExtraStyle(.window)`): a one-line summary, a capped
/// scrollable list of repos, and footer bulk actions. Shares the same live
/// `AppModel`/`RepoViewModel` state as the full window — there is no
/// separate refresh cadence for the menu bar (see the brief's YAGNI note).
/// The full window remains the primary surface; row-tap and the footer's
/// "Open RepoDeck" both bring it forward rather than duplicating any
/// per-repo actions here.
struct MenuBarContentView: View {
    /// Rows shown before falling back to a trailing "…and K more" line —
    /// keeps the popover glanceable rather than growing unbounded with the
    /// tracked repo count.
    private static let rowCap = 12

    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        Text("\(model.repos.count) repos · \(dirtyRepoCount) dirty")
            .font(theme.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(displayedRepos) { vm in
                    MenuBarRepoRow(vm: vm) {
                        openRepo(vm)
                    }
                }
                if remainingCount > 0 {
                    Text("…and \(remainingCount) more")
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 320)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Fetch All") {
                    Task { await model.fetchAll() }
                }
                .disabled(bulkActionsDisabled)

                Button("Pull All") {
                    Task { await model.pullAll() }
                }
                .disabled(bulkActionsDisabled)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }

            Button("Open RepoDeck") {
                openMainWindow()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    /// Mirrors `ContentView`'s toolbar disable condition for Fetch
    /// All/Pull All: a bulk op is already running, or a rescan is in flight.
    private var bulkActionsDisabled: Bool {
        model.bulkProgress != nil || model.isScanning
    }

    private var dirtyRepoCount: Int {
        model.repos.filter { ($0.status?.dirtyCount ?? 0) > 0 }.count
    }

    /// Pinned repos (alphabetical) first, then the rest sorted by dirty
    /// count descending (then name) — combined and capped at `rowCap`.
    private var displayedRepos: [RepoViewModel] {
        Array((pinnedRepos + dirtiestOthers).prefix(Self.rowCap))
    }

    private var remainingCount: Int {
        max(0, model.repos.count - displayedRepos.count)
    }

    private var pinnedRepos: [RepoViewModel] {
        model.repos
            .filter { model.settings(for: $0.id).isPinned }
            .sorted { $0.repo.name.localizedCaseInsensitiveCompare($1.repo.name) == .orderedAscending }
    }

    private var dirtiestOthers: [RepoViewModel] {
        model.repos
            .filter { !model.settings(for: $0.id).isPinned }
            .sorted { lhs, rhs in
                let lhsDirty = lhs.status?.dirtyCount ?? 0
                let rhsDirty = rhs.status?.dirtyCount ?? 0
                if lhsDirty != rhsDirty { return lhsDirty > rhsDirty }
                return lhs.repo.name.localizedCaseInsensitiveCompare(rhs.repo.name) == .orderedAscending
            }
    }

    private func openRepo(_ vm: RepoViewModel) {
        model.selectedRepoID = vm.id
        openMainWindow()
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One row in the menu-bar repo list: name, branch, ahead/behind, and a
/// dirty dot. The ahead/behind and dirty logic is intentionally duplicated
/// from `RepoRowView` (tiny, self-contained) rather than factored out —
/// the brief calls for reuse-by-duplication here, not a `RepoRowView` refactor.
private struct MenuBarRepoRow: View {
    let vm: RepoViewModel
    let onTap: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.repo.name)
                        .font(theme.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let branch = vm.status?.branch {
                        Text(branch)
                            .font(theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if let aheadBehindText {
                    Text(aheadBehindText)
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                }

                if dirtyCount > 0 {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dirtyCount: Int { vm.status?.dirtyCount ?? 0 }

    private var aheadBehindText: String? {
        guard let status = vm.status else { return nil }
        var parts: [String] = []
        if let ahead = status.ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind = status.behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
