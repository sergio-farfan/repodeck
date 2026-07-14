import AppKit
import RepoDeckKit
import SwiftUI

/// A single changed file: status badge, filename, dimmed path context, and an
/// optional trailing stage/unstage button. Double-click (or the context
/// menu's "Open in Editor") opens text files in TextEdit; binary and deleted
/// files offer no open affordance.
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

    /// TextEdit's fixed system location — same hardcoded-path convention as
    /// Terminal in RepoRowView.
    private static let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

    /// The file's on-disk URL when it exists, is readable, and sniffs as
    /// text — nil suppresses every open affordance (binaries, deleted or
    /// unreadable files). Does file I/O: reference it only inside the tap
    /// handler and the context-menu builder (both evaluated on interaction),
    /// never in the row body itself.
    private var editableFileURL: URL? {
        let url = vm.repo.path.appendingPathComponent(change.path)
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: BinarySniffer.sniffLength) else { return nil }
        return BinarySniffer.isLikelyBinary(data) ? nil : url
    }

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
                        .font(theme.mono(10))
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
            openInTextEdit()
        }
        .contextMenu {
            if editableFileURL != nil {
                Button("Open in Editor") {
                    openInTextEdit()
                }
            }
        }
    }

    private func openInTextEdit() {
        guard let url = editableFileURL else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Self.textEditURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
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
