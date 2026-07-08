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
            }
        }
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
