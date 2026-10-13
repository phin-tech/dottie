import SwiftUI
import DottieKit

/// UserDefaults keys and fallbacks for the Settings window. Read with `@AppStorage`.
enum Pref {
    static let roughness = "defaultRoughness"
    static let strokeWidth = "defaultStrokeWidth"
    static let routing = "defaultRouting"

    static let roughnessDefault = 1.0
    static let strokeWidthDefault = 2.0
    static let routingDefault = Routing.straight.rawValue
}

/// Opened with ⌘, from the app menu (the `Settings` scene wires the menu item and shortcut).
struct SettingsView: View {
    @AppStorage(Pref.roughness) private var roughness = Pref.roughnessDefault
    @AppStorage(Pref.strokeWidth) private var strokeWidth = Pref.strokeWidthDefault
    @AppStorage(Pref.routing) private var routing = Pref.routingDefault

    var body: some View {
        Form {
            Section {
                Picker("Look", selection: lookBinding) {
                    Text("Sketchy").tag(true)
                    Text("Clean").tag(false)
                }
                .pickerStyle(.segmented)
                Slider(value: $roughness, in: 0...3) { Text("Sketchiness") }
                    .disabled(roughness == 0)
                Slider(value: $strokeWidth, in: 1...12) { Text("Stroke width") }
                Picker("Connector routing", selection: $routing) {
                    Text("Straight").tag(Routing.straight.rawValue)
                    Text("Curved").tag(Routing.curved.rawValue)
                    Text("Elbow").tag(Routing.elbow.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("New shapes")
            } footer: {
                Text("Applies to shapes you draw from now on. Existing shapes keep their style.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Defaults") {
                    roughness = Pref.roughnessDefault
                    strokeWidth = Pref.strokeWidthDefault
                    routing = Pref.routingDefault
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Sketchy (roughness 1 unless already set) vs clean (0), mirroring the inspector.
    private var lookBinding: Binding<Bool> {
        Binding(get: { roughness > 0 }, set: { roughness = $0 ? max(Pref.roughnessDefault, 1) : 0 })
    }
}
