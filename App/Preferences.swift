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
    static let mcpBinaryPath = "mcpBinaryPath"
    static let settingsTab = "settingsTab"
    static let appearance = "appearance"
    static let showRulers = "showRulers"

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

/// App-wide light/dark override. `system` follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    static var stored: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Pref.appearance) ?? "") ?? .system
    }

    /// Uses `NSApplication.shared`, not `NSApp`: this runs from `App.init()`, before `NSApp` is set.
    @MainActor func apply() {
        let app = NSApplication.shared
        switch self {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// ⌘, window. Holds general, infrequently changed options; the style for new shapes lives in the
/// inspector, next to the shapes it affects, and is remembered between launches.
struct SettingsView: View {
    @AppStorage(Pref.settingsTab) private var tab = "general" // restore the last viewed pane

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MCPSettings()
                .tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag("mcp")
        }
        .frame(width: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Pref.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(Pref.snapToObjects) private var snapToObjects = true
    @AppStorage(Pref.snapToGrid) private var snapToGrid = false
    @AppStorage(Pref.gridSize) private var gridSize = Pref.gridSizeDefault
    @AppStorage(Pref.singleKeyShortcuts) private var singleKeyShortcuts = true
    @AppStorage(Pref.newStyle) private var newStyle = ""
    @AppStorage(Pref.routing) private var routing = Pref.routingDefault

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Canvas and windows", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, v in (AppearanceMode(rawValue: v) ?? .system).apply() }
            }
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
        .fixedSize(horizontal: false, vertical: true)
    }
}
