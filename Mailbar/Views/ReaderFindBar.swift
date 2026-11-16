import SwiftUI

/// Find in the open message (M22): a small bar floating over the body's top right, as Safari's
/// and Mail's do, so the body does not move when it opens. Typing searches at once; Return goes
/// to the next match and Shift+Return to the one before (Cmd+G and Shift+Cmd+G too); Escape
/// closes it and takes the marks out.
struct ReaderFindBar: View {
    @Bindable var web: ReaderWebController
    /// Bumped by Cmd+F while the bar is already open, to put the cursor back in the field.
    var focusRequest = 0
    let onClose: () -> Void

    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find in Message", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .frame(minWidth: 110)
                .onSubmit { Task { await web.step(1) } }
            Text(web.findLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(web.findTotal == 0 ? Color.orange : Color.secondary)
                .fixedSize()
            HStack(spacing: 2) {
                arrow("chevron.up", help: "Previous  ⇧↩") { Task { await web.step(-1) } }
                arrow("chevron.down", help: "Next  ↩") { Task { await web.step(1) } }
            }
            .disabled(web.findTotal == 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Done  esc")
            .accessibilityLabel("Close Find")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12)))
        .frame(width: 290)
        .background {
            // Key equivalents only, never seen: Shift+Return and Cmd+G go back and forth.
            ZStack {
                Button("") { Task { await web.step(-1) } }.keyboardShortcut(.return, modifiers: .shift)
                Button("") { Task { await web.step(1) } }.keyboardShortcut("g", modifiers: .command)
                Button("") { Task { await web.step(-1) } }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .buttonStyle(.plain)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            query = web.findQuery.isEmpty ? (QCFlags.readerFind ?? "") : web.findQuery
            focused = true
        }
        .onChange(of: focusRequest) { focused = true }
        .onChange(of: query) { _, text in
            Task { await web.find(text) }
        }
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
