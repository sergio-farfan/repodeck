import AppKit
import RepoDeckCore
import RepoDeckKit
import UniformTypeIdentifiers

extension AppModel {
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { addFolders(panel.urls) }
    }
}

@MainActor
enum PlatformApplications {
    static func chooseApplication(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
    static func chooseExecutable(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
    static func displayName(_ path: String?, fallback: String) -> String {
        guard let path, !path.isEmpty else { return fallback }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

extension AppModel {
    func openInEditor(_ url: URL, repoID: String) {
        var application = settings(for: repoID).editorApplicationPath ?? workflowSettings.editorApplicationPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            reportOpenFailure("The file or folder no longer exists.", repoID: repoID); return
        }
        // Files honor their default macOS association. A repository directory
        // needs an editor choice; its default association would merely open Finder.
        if application.isEmpty, isDirectory.boolValue {
            guard let chosen = PlatformApplications.chooseApplication(title: "Choose an Editor for Repositories") else { return }
            application = chosen
            var value = workflowSettings
            value.editorApplicationPath = chosen
            updateWorkflowSettings(value)
        }
        openUsingApplication(url, path: application, repoID: repoID)
    }
    func openInTerminal(_ url: URL, repoID: String) {
        let application = settings(for: repoID).terminalApplicationPath ?? workflowSettings.terminalApplicationPath
        guard !application.isEmpty else {
            guard let chosen = PlatformApplications.chooseApplication(title: "Choose a Terminal Application") else { return }
            var value = workflowSettings; value.terminalApplicationPath = chosen; updateWorkflowSettings(value)
            openUsingApplication(url, path: chosen, repoID: repoID); return
        }
        openUsingApplication(url, path: application, repoID: repoID)
    }
    private func openUsingApplication(_ url: URL, path: String, repoID: String) {
        if path.isEmpty {
            if !NSWorkspace.shared.open(url) { reportOpenFailure("macOS could not find an application for this file.", repoID: repoID) }
            return
        }
        guard path.hasPrefix("/"), path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
            reportOpenFailure("The configured application is unavailable. Choose an installed application in Settings.", repoID: repoID); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in self?.reportOpenFailure(message, repoID: repoID) }
        }
    }
    private func reportOpenFailure(_ message: String, repoID: String) {
        if let vm = repos.first(where: { $0.id == repoID }) {
            vm.actionError = GitError(command: "Open application", exitCode: -1, stderr: message)
        } else { settingsError = message }
    }
}
