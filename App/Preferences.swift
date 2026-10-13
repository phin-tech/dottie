import SwiftUI
import DottieKit

/// UserDefaults keys and fallbacks. Read with `@AppStorage`, or `Pref.bool` from AppKit code.
enum Pref {
    /// The inspector's "style for new shapes", persisted as JSON so it survives relaunch.
    static let newStyle = "newShapeStyle"
    static let routing = "defaultRouting"
    static let snapToObjects = "snapToObjects"
    static let snapToGrid = "snapToGrid"
    static let gridSize = "gridSize"
    static let singleKeyShortcuts = "singleKeyToolShortcuts"

    static let routingDefault = Routing.straight.rawValue
    static let gridSizeDefault = 20.0

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static func encode(_ style: Style) -> String {
        (try? JSONEncoder().encode(style)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func decodeStyle(_ json: String) -> Style? {
        try? JSONDecoder().decode(Style.self, from: Data(json.utf8))
    }
}

/// ⌘, window. Holds general, infrequently changed options; the style for new shapes lives in the
/// inspector, next to the shapes it affects, and is remembered between launches.
struct SettingsView: View {
    @AppStorage(Pref.snapToObjects) private var snapToObjects = true
    @AppStorage(Pref.snapToGrid) private var snapToGrid = false
    @AppStorage(Pref.gridSize) private var gridSize = Pref.gridSizeDefault
    @AppStorage(Pref.singleKeyShortcuts) private var singleKeyShortcuts = true
    @AppStorage(Pref.newStyle) private var newStyle = ""
    @AppStorage(Pref.routing) private var routing = Pref.routingDefault

    var body: some View {
        Form {
            Section {
                Toggle("Snap to other shapes", isOn: $snapToObjects)
                Toggle("Snap to grid", isOn: $snapToGrid)
                Stepper(value: $gridSize, in: 4...100, step: 2) {
                    LabeledContent("Grid size", value: "\(Int(gridSize)) pt")
                }
                .disabled(!snapToGrid)
            } header: {
                Text("Snapping")
            } footer: {
                Text("Hold ⌘ while dragging to bypass snapping.").foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Single-key tool shortcuts (V, R, O, D, T, C, P)", isOn: $singleKeyShortcuts)
            }
            Section {
                Button("Reset Style for New Shapes") {
                    newStyle = ""
                    routing = Pref.routingDefault
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("Dottie Settings")
    }
}
