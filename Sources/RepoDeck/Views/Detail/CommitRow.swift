import AppKit
import RepoDeckKit
import SwiftUI

/// A single commit: subject with trailing ref capsules on line 1, then a
/// secondary line with author, relative date, and monospaced short hash.
/// Context menu copies the full hash or the subject to the pasteboard.
struct CommitRow: View {
    @Environment(\.theme) private var theme
    let commit: Commit

    /// Ref capsules beyond this count collapse into a single "+N" overflow
    /// capsule, keeping the row compact.
    private static let maxVisibleRefs = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(commit.subject)
                    .font(theme.body)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                refCapsules
            }

            HStack(spacing: 4) {
                Text(commit.author)
                    .lineLimit(1)
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
                Spacer(minLength: 4)
                Text(commit.shortHash)
                    .font(theme.mono(11))
            }
            .font(theme.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Hash") {
                copyToPasteboard(commit.hash)
            }
            Button("Copy Subject") {
                copyToPasteboard(commit.subject)
            }
        }
    }

    @ViewBuilder
    private var refCapsules: some View {
        if !commit.refs.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(visibleRefs.enumerated()), id: \.offset) { _, ref in
                    RefCapsule(label: ref.label, color: ref.color)
                }
                if overflowCount > 0 {
                    RefCapsule(label: "+\(overflowCount)", color: .secondary)
                }
            }
        }
    }

    private var visibleRefs: [(label: String, color: Color)] {
        commit.refs.prefix(Self.maxVisibleRefs).map(Self.classify)
    }

    private var overflowCount: Int {
        max(commit.refs.count - Self.maxVisibleRefs, 0)
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Classifies a raw `%D` ref token into a short display label and a
    /// tint: blue for the checked-out branch (`HEAD -> …`, or bare `HEAD` in
    /// detached state) and other local branches, gray for `origin/…`
    /// remote-tracking branches, orange for `tag: …`.
    private static func classify(_ ref: String) -> (label: String, color: Color) {
        if ref.hasPrefix("HEAD -> ") {
            return (String(ref.dropFirst("HEAD -> ".count)), .blue)
        }
        if ref == "HEAD" {
            return ("HEAD", .blue)
        }
        if ref.hasPrefix("tag: ") {
            return (String(ref.dropFirst("tag: ".count)), .orange)
        }
        if ref.hasPrefix("origin/") {
            return (ref, .gray)
        }
        return (ref, .blue)
    }
}

/// Small tinted capsule for a single ref/tag label, `.caption2` sized to
/// match VS Code's graph-panel density.
private struct RefCapsule: View {
    @Environment(\.theme) private var theme
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(theme.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.2), in: Capsule())
    }
}
