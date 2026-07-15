import RepoDeckKit
import SwiftUI

/// Read-only rendering of `vm.diffFiles` — a working file's diff or every
/// file touched by a commit — hosted in `RepoDetailView`'s trailing
/// `.inspector`. Loaded by `RepoViewModel.showDiff(_:)`, triggered from the
/// "View Diff" item in `FileChangeRow`/`CommitRow`'s context menus.
///
/// v1 scope only: no syntax highlighting, no side-by-side, no word-level
/// diff — a single scrolling unified view per file, hunk headers, and a
/// two-column line-number gutter.
struct DiffView: View {
    @Environment(\.theme) private var theme
    @Bindable var vm: RepoViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Diff")
                .font(theme.title)
            Spacer()
            Button {
                vm.diffTarget = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingDiff {
            ProgressView("Loading diff…")
                .padding(40)
        } else if let diffError = vm.diffError {
            Text(diffError)
                .font(theme.mono(11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if vm.diffFiles.isEmpty {
            ContentUnavailableView("No Changes to Show", systemImage: "doc.text.magnifyingglass")
        } else {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(vm.diffFiles) { file in
                    fileSection(file)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func fileSection(_ file: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fileHeader(file)
            if file.isBinary {
                Text("Binary")
                    .font(theme.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(file.hunks) { hunk in
                    hunkHeader(hunk, file: file)
                    ForEach(hunk.lines, id: \.self) { line in
                        DiffLineRow(line: line)
                    }
                }
            }
        }
    }

    /// A hunk's `@@` header, plus — when `vm.diffHunkAction` says this diff
    /// supports it (an unstaged or staged working-file diff; never a commit
    /// diff) — a small Stage/Unstage button that mirrors
    /// `FileChangeRow`'s whole-file action button: icon-only
    /// (`plus.circle`/`minus.circle`), `.borderless`, disabled while
    /// `vm.isBusy`, with the direction's name as the tooltip. The read-only
    /// gutter/tint rendering below is unchanged either way.
    @ViewBuilder
    private func hunkHeader(_ hunk: Hunk, file: FileDiff) -> some View {
        HStack {
            Text(hunk.header)
                .font(theme.mono(10))
                .foregroundStyle(.secondary)
            Spacer()
            if let action = vm.diffHunkAction {
                Button {
                    Task {
                        switch action {
                        case .stage: await vm.stageHunk(hunk, in: file)
                        case .unstage: await vm.unstageHunk(hunk, in: file)
                        }
                    }
                } label: {
                    Image(systemName: action == .stage ? "plus.circle" : "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(vm.isBusy)
                .help(action == .stage ? "Stage Hunk" : "Unstage Hunk")
            }
        }
    }

    /// `doc.text` + `displayPath`, or an `old → new` arrow when `file` is a
    /// rename (paths differ and neither side is `/dev/null` — an add/delete
    /// always has one side as `/dev/null`, so this can't misfire on those).
    private func fileHeader(_ file: FileDiff) -> some View {
        let isRename = file.oldPath != file.newPath
            && file.oldPath != "/dev/null" && file.newPath != "/dev/null"
        return HStack(spacing: 6) {
            Image(systemName: "doc.text")
            Text(isRename ? "\(file.oldPath) → \(file.newPath)" : file.displayPath)
                .font(theme.body.bold())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// One diff line: a fixed-width old|new line-number gutter (blank when the
/// side has no line — additions have no old, deletions have no new), then
/// the line text verbatim — no trimming, so leading whitespace survives —
/// tinted by `kind`.
private struct DiffLineRow: View {
    @Environment(\.theme) private var theme
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            gutter(line.oldLine)
            gutter(line.newLine)
            Text(line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(theme.mono(11))
        .padding(.horizontal, 4)
        .background(tint)
        .textSelection(.enabled)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var tint: Color {
        switch line.kind {
        case .addition: .green.opacity(0.15)
        case .deletion: .red.opacity(0.15)
        case .context: .clear
        }
    }
}
