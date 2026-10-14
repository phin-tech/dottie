import Foundation
import CoreGraphics

/// A page look: the canvas color and the color automatic ink takes on it. Stored on a drawing by name,
/// so a file opens the same everywhere and exports match what you drew on.
public struct Theme: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var background: RGBA
    /// What automatic ink (the default stroke) is drawn and exported as.
    public var ink: RGBA

    public var isDark: Bool { background.luminance < 0.5 }

    public static let paper = Theme(id: "paper", name: "Paper", background: RGBA(r: 0.984, g: 0.980, b: 0.965),
                                    ink: RGBA(r: 0.12, g: 0.12, b: 0.13))
    public static let white = Theme(id: "white", name: "White", background: RGBA(r: 1, g: 1, b: 1), ink: .black)
    public static let sepia = Theme(id: "sepia", name: "Sepia", background: RGBA(r: 0.953, g: 0.914, b: 0.824),
                                    ink: RGBA(r: 0.23, g: 0.18, b: 0.13))
    public static let blueprint = Theme(id: "blueprint", name: "Blueprint", background: RGBA(r: 0.106, g: 0.227, b: 0.361),
                                        ink: RGBA(r: 0.91, g: 0.945, b: 0.984))
    public static let chalkboard = Theme(id: "chalkboard", name: "Chalkboard", background: RGBA(r: 0.169, g: 0.227, b: 0.2),
                                         ink: RGBA(r: 0.945, g: 0.945, b: 0.918))
    public static let midnight = Theme(id: "midnight", name: "Midnight", background: RGBA(r: 0.082, g: 0.086, b: 0.102),
                                       ink: RGBA(r: 0.925, g: 0.925, b: 0.94))

    public static let all: [Theme] = [.paper, .white, .sepia, .blueprint, .chalkboard, .midnight]

    public static func named(_ id: String?) -> Theme? { all.first { $0.id == id } }
}

extension DottieDocument {
    /// The theme chosen for this drawing, or nil to follow the system appearance.
    public var resolvedTheme: Theme? { Theme.named(theme) }
}
