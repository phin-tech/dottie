import SwiftUI
import AppKit
import DottieKit

extension ExtensionValue {
    var asNumber: Double { if case .number(let n) = self { n } else { 0 } }
    var asBool: Bool { if case .bool(let b) = self { b } else { false } }
    var asText: String { if case .string(let s) = self { s } else { "" } }
}

/// One parameter's control. The command form and the inspector both build their controls from a `ParameterSpec`.
struct ExtensionParameterControl: View {
    var spec: ParameterSpec
    @Binding var value: ExtensionValue

    private var title: String { spec.label ?? spec.name }

    private var number: Binding<Double> {
        Binding(get: { value.asNumber }, set: { value = .number($0) })
    }

    private var integer: Binding<Int> {
        Binding(get: { Int(value.asNumber.rounded()) }, set: { value = .number(Double($0)) })
    }

    private var flag: Binding<Bool> {
        Binding(get: { value.asBool }, set: { value = .bool($0) })
    }

    private var text: Binding<String> {
        Binding(get: { value.asText }, set: { value = .string($0) })
    }

    var body: some View {
        switch spec.type {
        case .number:
            if let lo = spec.min, let hi = spec.max, lo < hi {
                LabeledContent(title) {
                    HStack(spacing: 8) {
                        Slider(value: number, in: lo...hi).labelsHidden()
                        Text(value.asNumber.formatted(.number.precision(.fractionLength(0...2))))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }
                }
            } else {
                LabeledContent(title) {
                    TextField("", value: number, format: .number.precision(.fractionLength(0...4)))
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
            }
        case .integer:
            if let lo = spec.min, let hi = spec.max, lo <= hi {
                Stepper(value: integer, in: Int(lo.rounded(.up))...Int(hi.rounded(.down))) {
                    LabeledContent(title, value: "\(integer.wrappedValue)")
                }
            } else {
                Stepper(value: integer) { LabeledContent(title, value: "\(integer.wrappedValue)") }
            }
        case .boolean:
            Toggle(title, isOn: flag)
        case .enumeration:
            Picker(title, selection: text) {
                ForEach(spec.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        case .string:
            LabeledContent(title) {
                TextField("", text: text).multilineTextAlignment(.trailing)
            }
        }
    }
}

/// A command's form. Its values run the command on the canvas as they change, without an undo step. Run commits
/// the result as one step; Cancel, or any other way out, puts the page back as it was.
struct ExtensionCommandSheet: View {
    var command: CommandDefinition
    /// Runs the command with these values on the canvas; returns the problem when it fails.
    var preview: ([String: ExtensionValue]) -> String?
    /// Puts the page back as it was when the form opened.
    var revert: () -> Void
    /// Commits the command with these values; returns the problem, and the form stays open, when it fails.
    var run: ([String: ExtensionValue]) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: ExtensionValue]
    @State private var problem: String?
    @State private var ran = false

    init(command: CommandDefinition, preview: @escaping ([String: ExtensionValue]) -> String?,
         revert: @escaping () -> Void, run: @escaping ([String: ExtensionValue]) -> String?) {
        self.command = command
        self.preview = preview
        self.revert = revert
        self.run = run
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: command.parameters.map { ($0.name, $0.default) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(command.name).font(.headline)
            Form {
                ForEach(command.parameters, id: \.name) { spec in
                    ExtensionParameterControl(spec: spec, value: binding(spec))
                }
            }
            .formStyle(.grouped)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    if let error = run(values) { problem = error } else { ran = true; dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear { problem = preview(values) }
        .onChange(of: values) { _, v in problem = preview(v) }
        .onDisappear { if !ran { revert() } }
    }

    private func binding(_ spec: ParameterSpec) -> Binding<ExtensionValue> {
        Binding(get: { values[spec.name] ?? spec.default }, set: { values[spec.name] = $0 })
    }
}

/// The inspector's section for an extension shape: its parameters, from the extension's schema. Each change
/// regenerates the shape as one undo step. A failure is shown here and the shape keeps its last good path.
struct ExtensionShapeSection: View {
    @ObservedObject private var host = ExtensionHost.shared
    @ObservedObject var document: DrawingDocument
    var elementID: UUID
    var ref: ExtensionRef
    var undoManager: UndoManager?
    @State private var problem: String?

    var body: some View {
        let runtime = host.runtime(for: ref.id)
        let shape = runtime?.shape(named: ref.shape)
        Section {
            if let runtime, let shape {
                LabeledContent("Version", value: runtime.manifest.version)
                ForEach(shape.parameters, id: \.name) { spec in
                    ExtensionParameterControl(spec: spec, value: binding(spec))
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } else {
                Text("The extension for this shape is off or missing. The shape keeps its current path.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(shape?.name ?? ref.shape)
        }
    }

    private func binding(_ spec: ParameterSpec) -> Binding<ExtensionValue> {
        Binding(get: { ref.params[spec.name] ?? spec.default }, set: { change(spec.name, to: $0) })
    }

    private func change(_ name: String, to value: ExtensionValue) {
        guard let runtime = ExtensionHost.shared.runtime(for: ref.id) else { return }
        var next = document.model
        guard let i = next.elements.firstIndex(where: { $0.id == elementID }), var stored = next.elements[i].extension else { return }
        stored.params[name] = value
        next.elements[i].extension = stored
        do {
            try next.elements[i].regenerate(with: runtime)
        } catch {
            problem = ExtensionHost.message(error)
            return
        }
        problem = nil
        document.commit(next, actionName: "Change Shape", undoManager: undoManager)
    }
}

/// Settings ▸ Extensions: what is installed, which extensions are on, and what is wrong with the rest.
struct ExtensionsSettings: View {
    @ObservedObject private var host = ExtensionHost.shared

    var body: some View {
        let rows = host.bundles()
        Form {
            Section {
                if rows.isEmpty {
                    Text("No extensions installed.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in ExtensionRowView(row: row) }
            } header: {
                Text("Installed")
            } footer: {
                Text("Extensions run JavaScript that draws shapes and runs commands. They cannot read files or use the network.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: ExtensionRegistry.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ExtensionRegistry.folder)
                }
                Button("Reload") { host.reload() }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExtensionRowView: View {
    var row: ExtensionBundleRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name).fontWeight(.medium)
                if let version = row.version { Text("v\(version)").foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                if let id = row.extensionID {
                    Toggle("On", isOn: Binding(get: { !row.disabled }, set: { ExtensionHost.shared.setEnabled(id, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            if let id = row.extensionID {
                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if row.disabled {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
            if let error = row.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !row.shapes.isEmpty {
                Text("Shapes: " + row.shapes.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !row.commands.isEmpty {
                Text("Commands: " + row.commands.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
