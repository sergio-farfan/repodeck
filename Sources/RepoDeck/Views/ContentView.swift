import Foundation
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            RepoListView()
        } detail: {
            detailContent
        }
        .frame(minWidth: 800, minHeight: 500)
        .task {
            if !model.trackedFolders.isEmpty && model.repos.isEmpty {
                await model.rescan()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let bulkSummary = model.bulkSummary {
                bulkSummaryBanner(bulkSummary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.addFolders()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }

                Menu("Folders") {
                    ForEach(model.trackedFolders, id: \.self) { folder in
                        Menu(abbreviatedPath(folder)) {
                            Button("Remove") {
                                model.removeFolder(folder)
                            }
                        }
                    }
                }

                Button {
                    Task { await model.rescan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)

                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }

                Divider()

                Button {
                    Task { await model.fetchAll() }
                } label: {
                    Label("Fetch All", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.bulkProgress != nil || model.isScanning)

                Button {
                    Task { await model.pullAll() }
                } label: {
                    Label("Pull All", systemImage: "arrow.down.circle")
                }
                .disabled(model.bulkProgress != nil || model.isScanning)

                if let bulkProgress = model.bulkProgress {
                    ProgressView(value: Double(bulkProgress.done), total: Double(max(bulkProgress.total, 1))) {
                        Text("\(bulkProgress.verb) \(bulkProgress.done)/\(bulkProgress.total)")
                            .font(.caption)
                    }
                    .frame(width: 160)
                }
            }
        }
    }

    /// Transient, dismissible summary shown after a bulk fetch/pull finishes
    /// with at least one per-repo failure. The individual failures live in
    /// each repo's own `actionError`, surfaced by that repo's `ErrorBanner`
    /// once selected — this is just a toolbar-level count.
    private func bulkSummaryBanner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
            Spacer()
            Button {
                model.bulkSummary = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
    }

    @ViewBuilder
    private var detailContent: some View {
        if model.trackedFolders.isEmpty {
            ContentUnavailableView {
                Label("No Folders Added", systemImage: "folder.badge.plus")
            } description: {
                Text("Add a folder to discover git repositories.")
            } actions: {
                Button("Add Folder…") {
                    model.addFolders()
                }
            }
        } else if let selectedRepoID = model.selectedRepoID,
            let selected = model.repos.first(where: { $0.id == selectedRepoID }) {
            RepoDetailView(vm: selected)
        } else {
            ContentUnavailableView(
                "No Repository Selected",
                systemImage: "folder.badge.gearshape",
                description: Text("Choose a repository from the sidebar.")
            )
        }
    }

    private func abbreviatedPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
