import AppKit
import RepoDeckKit
import SwiftUI

/// What a row's icon communicates: a repo to jump to, or an action to run.
/// Kept local to this file (not `AppModel`) — palette items are a rendering
/// concern of this view, not app-wide state.
private enum PaletteItemKind {
    case repo
    case action

    var icon: String {
        switch self {
        case .repo: return "folder"
        case .action: return "bolt"
        }
    }
}

/// One row in the palette: title/subtitle to render, and the action to run
/// when it's chosen. Built fresh from `AppModel` on every render — never
/// persisted, never mutated in place.
private struct PaletteItem: Identifiable {
    let id: String
    let kind: PaletteItemKind
    let title: String
    let subtitle: String?
    let run: () -> Void

    var icon: String { kind.icon }
}

/// ⌘K command palette: a search-and-run overlay for jumping to a repo or
/// firing a global/selected-repo action, filtered by `MatchRanker`.
///
/// Mounted as a full-window `.overlay` from `ContentView`, gated on
/// `AppModel.isPaletteVisible`. Owns no persisted state of its own — `query`
/// and `selectionIndex` reset every time the overlay appears.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @FocusState private var isFieldFocused: Bool

    @State private var query = ""
    @State private var selectionIndex = 0

    private let rowHeight: CGFloat = 40
    private let maxVisibleRows = 12

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                Spacer().frame(height: 120)
                panel
                Spacer()
            }
        }
        .onAppear {
            query = ""
            selectionIndex = 0
            isFieldFocused = true
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type a command or repository…", text: $query)
                .textFieldStyle(.plain)
                .font(theme.body)
                .padding(12)
                .focused($isFieldFocused)
                .onChange(of: query) { selectionIndex = 0 }
                .onSubmit { runSelected() }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    runSelected()
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }

            Divider()

            if items.isEmpty {
                Text("No matches")
                    .font(theme.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, isSelected: index == selectionIndex)
                                .onTapGesture {
                                    selectionIndex = index
                                    runSelected()
                                }
                        }
                    }
                }
                .frame(maxHeight: rowHeight * CGFloat(min(items.count, maxVisibleRows)))
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 20)
        .frame(width: 560)
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(theme.body)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(isSelected ? theme.accent.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Item building

    /// All repos, unfiltered by the sidebar's `filterText` — the palette
    /// runs its own query against `title`.
    private func repoItem(for vm: RepoViewModel) -> PaletteItem {
        PaletteItem(
            id: "open-\(vm.id)",
            kind: .repo,
            title: "Open \(vm.repo.name)",
            subtitle: model.settings(for: vm.id).group,
            run: {
                model.selectedRepoID = vm.id
                model.filterText = ""
                close()
            }
        )
    }

    private var repoItems: [PaletteItem] {
        model.repos.map(repoItem(for:))
    }

    private var globalItems: [PaletteItem] {
        [
            PaletteItem(id: "global-fetch-all", kind: .action, title: "Fetch All", subtitle: nil, run: {
                Task { await model.fetchAll() }
                close()
            }),
            PaletteItem(id: "global-pull-all", kind: .action, title: "Pull All", subtitle: nil, run: {
                Task { await model.pullAll() }
                close()
            }),
            PaletteItem(id: "global-refresh", kind: .action, title: "Refresh Repositories", subtitle: nil, run: {
                Task { await model.rescan() }
                close()
            }),
        ]
    }

    /// Actions on `model.selectedRepoID`'s repo — empty when nothing is selected.
    private var selectedRepoActionItems: [PaletteItem] {
        guard let selectedRepoID = model.selectedRepoID,
              let vm = model.repos.first(where: { $0.id == selectedRepoID }) else {
            return []
        }
        let name = vm.repo.name
        return [
            PaletteItem(id: "selected-pull", kind: .action, title: "Pull — \(name)", subtitle: nil, run: {
                Task { await vm.pull() }
                close()
            }),
            PaletteItem(id: "selected-push", kind: .action, title: "Push — \(name)", subtitle: nil, run: {
                Task { await vm.push() }
                close()
            }),
            PaletteItem(id: "selected-fetch", kind: .action, title: "Fetch — \(name)", subtitle: nil, run: {
                Task { await vm.fetch() }
                close()
            }),
            PaletteItem(id: "selected-reveal", kind: .action, title: "Reveal in Finder — \(name)", subtitle: nil, run: {
                NSWorkspace.shared.activateFileViewerSelecting([vm.repo.path])
                close()
            }),
            PaletteItem(id: "selected-terminal", kind: .action, title: "Open in Terminal — \(name)", subtitle: nil, run: {
                NSWorkspace.shared.open(
                    [vm.repo.path],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
                close()
            }),
        ]
    }

    /// Ranked, filtered rows for the current `query`.
    ///
    /// Empty query: a curated default list — pinned repos (in `model.repos`
    /// order), then globals, then selected-repo actions — rather than the
    /// generic rank sort, since `MatchRanker` ranks every candidate 0 for an
    /// empty query and a title sort would interleave repos and commands.
    /// Non-empty query: every repo/global/selected-repo item ranked by
    /// `MatchRanker.rank(query, in: item.title)`, non-matches dropped, ties
    /// broken by title.
    private var items: [PaletteItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            let pinnedRepoItems = model.repos
                .filter { model.settings(for: $0.id).isPinned }
                .map(repoItem(for:))
            return pinnedRepoItems + globalItems + selectedRepoActionItems
        }

        return (repoItems + globalItems + selectedRepoActionItems)
            .compactMap { item -> (item: PaletteItem, rank: Int)? in
                guard let rank = MatchRanker.rank(trimmedQuery, in: item.title) else { return nil }
                return (item, rank)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
            }
            .map(\.item)
    }

    // MARK: - Actions

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectionIndex = max(0, min(items.count - 1, selectionIndex + delta))
    }

    private func runSelected() {
        guard items.indices.contains(selectionIndex) else { return }
        items[selectionIndex].run()
    }

    private func close() {
        model.isPaletteVisible = false
    }
}
