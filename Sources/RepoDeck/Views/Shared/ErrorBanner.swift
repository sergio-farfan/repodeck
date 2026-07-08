import RepoDeckKit
import SwiftUI

/// Dismissible, non-modal banner for a repo's most recent action failure.
///
/// Shows the failed `git` invocation (`GitError.command`) above the raw
/// `stderr` text, so a log-refresh failure that lands right after a
/// successful commit reads as "git log ... failed", not "your commit
/// failed" — the two are otherwise indistinguishable once they share the
/// same `actionError` slot. Never presented as a modal alert; the caller
/// mounts it inline and it collapses to nothing when `error` is nil.
struct ErrorBanner: View {
    @Binding var error: GitError?

    var body: some View {
        if let error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(error.command)
                        .font(.caption.bold())
                    Text(error.stderr.isEmpty ? "git exited with \(error.exitCode)" : error.stderr)
                        .font(.caption.monospaced())
                }
                .textSelection(.enabled)

                Spacer(minLength: 8)

                Button {
                    self.error = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(8)
            .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }
}
