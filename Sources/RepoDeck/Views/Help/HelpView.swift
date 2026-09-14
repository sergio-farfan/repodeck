import Observation
import RepoDeckCore
import SwiftUI

/// Shared with contextual Help buttons; opening an existing window updates it.
@MainActor
enum HelpWindow {
    static let id = "help"

    static func open(_ topic: HelpTopicID = .gettingStarted, using openWindow: OpenWindowAction) {
        HelpWindowState.shared.navigate(to: topic)
        openWindow(id: id)
    }
}

@Observable @MainActor
private final class HelpWindowState {
    static let shared = HelpWindowState()
    var query = ""
    var selectedTopic: HelpTopicID? = .gettingStarted
    private var history: [HelpTopicID] = [.gettingStarted]
    private var historyIndex = 0

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex + 1 < history.count }

    func navigate(to topic: HelpTopicID, clearSearch: Bool = true) {
        if clearSearch { query = "" }
        selectedTopic = topic
        guard history[historyIndex] != topic else { return }
        history = Array(history.prefix(historyIndex + 1))
        history.append(topic)
        historyIndex = history.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        query = ""
        selectedTopic = history[historyIndex]
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        query = ""
        selectedTopic = history[historyIndex]
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("RepoDeck Help") { HelpWindow.open(using: openWindow) }
                .keyboardShortcut("?", modifiers: .command)
            Button("Troubleshooting") { HelpWindow.open(.troubleshooting, using: openWindow) }
        }
    }
}

struct HelpView: View {
    @Environment(\.theme) private var theme
    @State private var state = HelpWindowState.shared
    @FocusState private var searchFocused: Bool

    private var results: [HelpArticle] { HelpContent.search(state.query) }
    private var isSearching: Bool { !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedArticle: HelpArticle? { state.selectedTopic.flatMap(HelpContent.article) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                searchField
                topicList
                Text("Available offline")
                    .font(theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let selectedArticle, results.contains(where: { $0.id == selectedArticle.id }) {
                articleView(selectedArticle)
                    .id(selectedArticle.id)
            } else {
                ContentUnavailableView {
                    Label("No Help Topics Found", systemImage: "magnifyingglass")
                } description: {
                    Text("Try fewer words, an action such as “push”, or an error such as “permission denied”.")
                } actions: {
                    Button("Show All Topics") { state.navigate(to: .gettingStarted) }
                }
            }
        }
        .navigationTitle("RepoDeck Help")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { state.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!state.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous help topic")
                Button { state.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!state.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Next help topic")
                Button { state.navigate(to: .gettingStarted) } label: { Label("Help Home", systemImage: "house") }
                    .help("Show all help topics")
            }
            ToolbarItem {
                Button { searchFocused = true } label: { Label("Search Help", systemImage: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search help topics (⌘F)")
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onChange(of: state.query) {
            if !results.contains(where: { $0.id == state.selectedTopic }) {
                if let first = results.first {
                    state.navigate(to: first.id, clearSearch: false)
                } else {
                    state.selectedTopic = nil
                }
            }
        }
    }

    private var searchField: some View {
        @Bindable var state = state
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search Help", text: $state.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search Help")
                .onSubmit {
                    if let first = results.first { state.navigate(to: first.id, clearSearch: false) }
                    searchFocused = false
                }
                .onExitCommand {
                    state.query = ""
                    searchFocused = false
                }
            if !state.query.isEmpty {
                Button { state.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear help search")
            }
        }
        .font(theme.body)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var topicList: some View {
        List(selection: Binding(get: { state.selectedTopic }, set: { topic in
            if let topic { state.navigate(to: topic, clearSearch: false) }
        })) {
            if isSearching {
                Section("\(results.count) matching \(results.count == 1 ? "topic" : "topics")") {
                    ForEach(results) { topicRow($0, showSummary: true) }
                }
            } else {
                ForEach(HelpCategory.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(results.filter { $0.category == category }) { topicRow($0, showSummary: false) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Help topics")
    }

    private func topicRow(_ article: HelpArticle, showSummary: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title).font(theme.body).fixedSize(horizontal: false, vertical: true)
                if showSummary {
                    Text(article.summary).font(theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: article.symbol)
        }
        .padding(.vertical, 3)
        .tag(article.id)
    }

    private func articleView(_ article: HelpArticle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(article.category.rawValue).font(theme.caption).foregroundStyle(.secondary)
                    Text(article.title).font(theme.ui(26, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text(article.summary).font(theme.ui(15)).foregroundStyle(.secondary)
                }
                ForEach(article.sections.indices, id: \.self) { index in
                    sectionView(article.sections[index])
                }
                if !article.related.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Related Topics").font(theme.title).accessibilityAddTraits(.isHeader)
                        ForEach(article.related, id: \.self) { id in
                            if let related = HelpContent.article(id) {
                                Button { state.navigate(to: id) } label: {
                                    Label(related.title, systemImage: "arrow.right.circle")
                                        .multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.link)
                                .font(theme.body)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel(article.title)
    }

    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title).font(theme.title).accessibilityAddTraits(.isHeader)
            ForEach(section.paragraphs.indices, id: \.self) { index in
                Text(section.paragraphs[index]).font(theme.body).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(section.steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(section.steps[index]).fixedSize(horizontal: false, vertical: true)
                }
                .font(theme.body)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
