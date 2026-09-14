import RepoDeckCore
import AppKit
import SwiftUI

/// The ⌘, Settings window: appearance mode, accent color, UI/monospace font
/// family, and base font size. Curated v1.1 scope — wiring these into
/// existing leaf views is Task 3.
struct SettingsView: View {
    @Environment(ThemeSettings.self) private var settings
    @Environment(AppModel.self) private var model
    @State private var workflow = WorkflowSettings()

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { model.isMenuBarExtraEnabled },
                    set: { model.isMenuBarExtraEnabled = $0 }
                ))
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(ThemeSettings.Appearance.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Accent") {
                ColorPicker("Accent Color", selection: $settings.accentColor)
            }

            Section("Fonts") {
                Picker("UI Font", selection: $settings.uiFontName) {
                    Text("System").tag(nil as String?)
                    ForEach(uiFontFamilies, id: \.self) { family in
                        Text(family).tag(family as String?)
                    }
                }

                Picker("Monospace Font", selection: $settings.monoFontName) {
                    Text("System Monospaced").tag(nil as String?)
                    ForEach(monoFontFamilies, id: \.self) { family in
                        Text(family).tag(family as String?)
                    }
                }
            }

            Section("Font Size") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Slider(value: $settings.baseFontSize, in: ThemeSettings.fontSizeRange, step: 1)
                            .accessibilityLabel("Base font size")
                            .accessibilityValue("\(Int(settings.baseFontSize)) points")
                        Text("\(Int(settings.baseFontSize))")
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                    }
                    previewLine
                }
            }

            Section("Developer Tools") {
                executableRow("Git", path: $workflow.gitPath, automatic: false)
                executableRow("GitHub CLI (gh)", path: $workflow.ghPath, automatic: true)
                executableRow("GitLab CLI (glab)", path: $workflow.glabPath, automatic: true)
                Text("Leave gh or glab blank to discover it on PATH. Authentication and host/account status are shown in each repository's Reviews workspace.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Applications") {
                applicationRow("Editor", path: $workflow.editorApplicationPath, fallback: "Default file application")
                applicationRow("Terminal", path: $workflow.terminalApplicationPath, fallback: "Choose when opened")
                Text("Repository Settings can override these applications for individual projects.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Apply Workflow Settings") { model.updateWorkflowSettings(workflow) }
                    .disabled(workflow == model.workflowSettings)
                if let error = model.settingsError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }

            Section {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 700)
        .padding(.vertical, 8)
        .onAppear { workflow = model.workflowSettings }
    }

    /// Live preview of the chosen UI and monospace fonts at the chosen size.
    private var previewLine: some View {
        let theme = Theme(settings: settings)
        return VStack(alignment: .leading, spacing: 2) {
            Text("The quick brown fox jumps over the lazy dog")
                .font(theme.body)
            Text("git commit -m \"fix\"")
                .font(theme.mono(13))
        }
    }

    private func executableRow(_ label: String, path: Binding<String>, automatic: Bool) -> some View {
        HStack {
            TextField(automatic ? "\(label) (automatic when blank)" : label, text: path)
                .textFieldStyle(.roundedBorder).accessibilityLabel("\(label) executable path")
            Button("Choose…") {
                if let selected = PlatformApplications.chooseExecutable(title: "Choose \(label)") { path.wrappedValue = selected }
            }.accessibilityLabel("Choose \(label) executable")
        }
    }
    private func applicationRow(_ label: String, path: Binding<String>, fallback: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(PlatformApplications.displayName(path.wrappedValue, fallback: fallback))
                .foregroundStyle(.secondary).lineLimit(1).help(path.wrappedValue)
            Button("Choose…") {
                if let selected = PlatformApplications.chooseApplication(title: "Choose \(label)") { path.wrappedValue = selected }
            }.accessibilityLabel("Choose \(label)")
            Button("Default") { path.wrappedValue = label == "Terminal" ? WorkflowSettings().terminalApplicationPath : "" }
                .accessibilityLabel("Reset \(label) to default")
        }
    }

    private var uiFontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }

    /// Families with at least one fixed-pitch member, per the brief's
    /// `NSFont(name:size:)?.isFixedPitch` heuristic.
    private var monoFontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return false }
                return members.contains { member in
                    guard let fontName = member.first as? String, let font = NSFont(name: fontName, size: 12) else {
                        return false
                    }
                    return font.isFixedPitch
                }
            }
            .sorted()
    }
}
