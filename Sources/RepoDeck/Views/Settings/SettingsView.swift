import AppKit
import SwiftUI

/// The ⌘, Settings window: appearance mode, accent color, UI/monospace font
/// family, and base font size. Curated v1.1 scope — wiring these into
/// existing leaf views is Task 3.
struct SettingsView: View {
    @Environment(ThemeSettings.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings

        Form {
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
                        Text("\(Int(settings.baseFontSize))")
                            .monospacedDigit()
                            .frame(width: 24, alignment: .trailing)
                    }
                    previewLine
                }
            }

            Section("Integrations") {
                LabeledContent("GitHub CLI (gh)") {
                    Label(ghStatusText, systemImage: ghStatusSymbol)
                        .foregroundStyle(model.isGhAvailable ? .green : .secondary)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }

    /// Live preview of the chosen UI and monospace fonts at the chosen size.
    private var previewLine: some View {
        let theme = Theme(settings: settings)
        return VStack(alignment: .leading, spacing: 2) {
            Text("The quick brown fox jumps over the lazy dog")
                .font(theme.ui(theme.baseSize))
            Text("git commit -m \"fix\"")
                .font(theme.mono(theme.baseSize))
        }
    }

    /// "Found and authenticated" / "Found, not signed in (run gh auth
    /// login)" / "Not installed" — the only three states `AppModel` can
    /// resolve `gh` into (`model.gh == nil` covers "not installed";
    /// `isGhAvailable` distinguishes the other two).
    private var ghStatusText: String {
        guard model.gh != nil else { return "Not installed" }
        return model.isGhAvailable ? "Found and authenticated" : "Found, not signed in (run gh auth login)"
    }

    private var ghStatusSymbol: String {
        guard model.gh != nil else { return "xmark.circle" }
        return model.isGhAvailable ? "checkmark.circle.fill" : "exclamationmark.circle"
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
