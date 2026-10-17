import SwiftUI

/// A name in a field, in a popover by the thing it names: Return commits, Esc (or clicking away) leaves it as it
/// was. `problem` explains why a name can't be used, or returns nil when it can; while there is one, the reason
/// shows in red in place of `hint` and the commit button is off. The name reaches `onCommit` trimmed.
///
///     .popover(item: $renaming) { m in
///         NamePopover(title: "Rename Scene", systemImage: "flag.fill", tint: .orange, name: m.name,
///                     problem: { $0.isEmpty ? "A scene needs a name." : nil }) { rename(m, to: $0) }
///     }
struct NamePopover: View {
    var title: String
    var systemImage: String
    var tint: Color = .accentColor
    var name: String
    var placeholder = "Name"
    /// A line under the field saying what renaming does, when it isn't obvious.
    var hint: String?
    var commitTitle = "Rename"
    var problem: (String) -> String? = { $0.isEmpty ? "It needs a name." : nil }
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String?
    @FocusState private var focused: Bool

    private var text: Binding<String> { Binding(get: { draft ?? name }, set: { draft = $0 }) }
    private var trimmed: String { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var reason: String? { problem(trimmed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(commit)
            if let line = reason ?? hint {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(reason == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(commitTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason != nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 244, alignment: .leading)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func commit() {
        guard reason == nil else { return }
        dismiss()
        if trimmed != name { onCommit(trimmed) }
    }
}
