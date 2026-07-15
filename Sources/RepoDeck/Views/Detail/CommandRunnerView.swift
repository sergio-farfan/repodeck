import SwiftUI

/// In-window, non-interactive command runner for one repo: a scrollback of
/// past commands + their output, and an input row to run a new one.
/// Deliberately not a terminal emulator — commands run to completion via
/// the user's login shell (CR-1's `ProcessRunner.runStreaming`); no PTY, no
/// stdin, no job control, no `vim`/`less`. Accepted tradeoff for staying
/// dependency-free (no embedded SwiftTerm).
///
/// Docked at the bottom of `RepoDetailView` via a nested `VerticalSplit`
/// whenever `vm.isCommandPaneVisible` is true; toggled from
/// `SyncControlsView` and the sidebar's "Open Command Runner" item.
struct CommandRunnerView: View {
    @Bindable var vm: RepoViewModel
    @Environment(\.theme) private var theme

    private static let bottomAnchorID = "CommandRunnerView.bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            scrollback
            Divider()
            CommandInputRow(vm: vm)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text(vm.repo.name)
                .font(theme.body.bold())
            Spacer()
            Button {
                vm.isCommandPaneVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close Command Runner")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var scrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(vm.commandOutput)
                    .font(theme.mono(11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)

                // Invisible anchor scrolled to on every output change, so
                // new output always brings the bottom of the scrollback
                // into view (a live `tail -f`-style command stays visible).
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
            .onChange(of: vm.commandOutput) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.accent.opacity(0.04))
    }
}

/// The bottom input row: a prompt glyph, the command `TextField`, and a
/// trailing Run/Stop button. Owns the up/down history-cursor `@State` —
/// `vm.commandHistory` is the source of truth; this is just "where in it am
/// I right now," reset on a new command or a hand-edit (vs. this view
/// recalling history into the field itself — see `isRecallingHistory`).
private struct CommandInputRow: View {
    @Bindable var vm: RepoViewModel
    @Environment(\.theme) private var theme

    /// `nil` = not cycling history (a fresh or hand-edited draft); otherwise
    /// counts back from the end of `vm.commandHistory` (`0` = most recent).
    @State private var historyCursor: Int?
    /// The in-progress draft as of the first up-arrow, restored once the
    /// user arrows back down past the most recent history entry.
    @State private var draftBeforeHistory: String = ""
    /// Set just before this view writes `vm.commandInput` itself, so the
    /// `onChange` below can tell a history recall apart from the user
    /// actually typing — only the latter resets `historyCursor`.
    @State private var isRecallingHistory = false

    var body: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(theme.mono(11))
                .foregroundStyle(.secondary)

            TextField("Run a command in \(vm.repo.name)…", text: $vm.commandInput)
                .font(theme.mono(11))
                .textFieldStyle(.plain)
                .disabled(vm.isRunningCommand)
                .onSubmit(runCommand)
                .onKeyPress(.upArrow) { recallHistory(older: true) }
                .onKeyPress(.downArrow) { recallHistory(older: false) }
                .onChange(of: vm.commandInput) {
                    if isRecallingHistory {
                        isRecallingHistory = false
                    } else {
                        historyCursor = nil
                    }
                }

            runOrStopButton
        }
        .padding(8)
    }

    @ViewBuilder
    private var runOrStopButton: some View {
        if vm.isRunningCommand {
            Button(action: vm.cancelCommand) {
                Image(systemName: "stop.fill")
            }
            .help("Stop")
        } else {
            Button("Run", action: runCommand)
                .disabled(vm.commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func runCommand() {
        historyCursor = nil
        draftBeforeHistory = ""
        vm.runCommand()
    }

    /// Cycles `vm.commandInput` through `vm.commandHistory`: up moves to an
    /// older entry (saving the in-progress draft on the first press), down
    /// moves back toward it and restores that draft once past the most
    /// recent entry. `.ignored` when there is nothing to recall, so the
    /// keypress falls through to the field's normal caret movement.
    private func recallHistory(older: Bool) -> KeyPress.Result {
        let history = vm.commandHistory
        guard !history.isEmpty else { return .ignored }

        if older {
            let next = (historyCursor ?? -1) + 1
            guard next < history.count else { return .handled }
            if historyCursor == nil { draftBeforeHistory = vm.commandInput }
            historyCursor = next
            setInput(history[history.count - 1 - next])
        } else {
            guard let current = historyCursor else { return .ignored }
            let next = current - 1
            historyCursor = next < 0 ? nil : next
            setInput(next < 0 ? draftBeforeHistory : history[history.count - 1 - next])
        }
        return .handled
    }

    private func setInput(_ value: String) {
        isRecallingHistory = true
        vm.commandInput = value
    }
}
