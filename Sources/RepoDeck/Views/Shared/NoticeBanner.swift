import SwiftUI

/// Dismissible, non-modal informational counterpart to `ErrorBanner`:
/// shown when an action succeeded but did something worth surfacing (e.g.
/// an auto-rebase before push). Same chrome and placement as `ErrorBanner`,
/// accent-tinted instead of red. Collapses to nothing when `notice` is nil.
struct NoticeBanner: View {
    @Binding var notice: String?

    var body: some View {
        if let notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)

                Text(notice)
                    .font(.caption)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }
}
