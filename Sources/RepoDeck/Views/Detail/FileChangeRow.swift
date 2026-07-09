import AppKit
import RepoDeckKit
import SwiftUI

/// A single changed file: status badge, filename, dimmed path context, and an
/// optional trailing stage/unstage button. Double-click (or the context
/// menu's "Open in Editor") opens the file in the user's default editor.
struct FileChangeRow: View {
    enum Action {
        case stage
        case unstage

        var systemImage: String {
            switch self {
            case .stage: "plus.circle"
            case .unstage: "minus.circle"
            }
        }

        var help: String {
            switch self {
            case .stage: "Stage"
            case .unstage: "Unstage"
            }
        }
    }

    @Environment(\.theme) private var theme
    let change: FileChange
    let vm: RepoViewModel
    let action: Action?

    var body: some View {
        HStack(spacing: 8) {
            StatusLetterBadge(letter: change.statusLetter)

            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .font(theme.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let dimmedText {
                    Text(dimmedText)
                        .font(theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let action {
                Button {
                    Task {
                        switch action {
                        case .stage: await vm.stage(change)
                        case .unstage: await vm.unstage(change)
                        }
                    }
                } label: {
                    Image(systemName: action.systemImage)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isBusy)
                .help(action.help)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(fileURL)
        }
        .contextMenu {
            Button("Open in Editor") {
                NSWorkspace.shared.open(fileURL)
            }
        }
    }

    private var fileURL: URL {
        vm.repo.path.appendingPathComponent(change.path)
    }

    private var fileName: String {
        (change.path as NSString).lastPathComponent
    }

    /// Directory prefix for a plain change; `originalPath → path` for renames/copies.
    private var dimmedText: String? {
        if let originalPath = change.originalPath {
            return "\(originalPath) → \(change.path)"
        }
        let directory = (change.path as NSString).deletingLastPathComponent
        return directory.isEmpty ? nil : directory
    }
}
