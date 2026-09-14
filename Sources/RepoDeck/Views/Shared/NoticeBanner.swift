import SwiftUI

/// Dismissible, non-modal informational counterpart to `ErrorBanner`:
/// shown when an action succeeded but did something worth surfacing (e.g.
/// an auto-rebase before push). Same chrome and placement as `ErrorBanner`,
/// accent-tinted instead of red. Collapses to nothing when `notice` is nil.
struct NoticeBanner: View {
    @Environment(\.theme) private var theme
    @Binding var notice: String?
    @State private var details: String?

    var body: some View {
        if let notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)

                Text(notice)
                    .font(theme.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Details…") { details = notice }

                Spacer(minLength: 8)

                Button {
                    self.notice = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss notice")
                .accessibilityLabel("Dismiss notice")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .sheet(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Operation notice").font(.title2)
                    ScrollView {
                        Text(details ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Spacer()
                        Button("Done") { details = nil }.keyboardShortcut(.defaultAction)
                    }
                }.padding(20).frame(width: 560, height: 360)
            }
        }
    }
}
