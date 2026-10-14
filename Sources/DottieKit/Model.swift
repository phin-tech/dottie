import Foundation
import CoreGraphics

public struct RGBA: Codable, Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let black = RGBA(r: 0.12, g: 0.12, b: 0.13)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    /// `black` is the automatic ink: shown as `inkOnDark` on a dark canvas, and always exported as black.
    public static let inkOnDark = RGBA(r: 0.93, g: 0.93, b: 0.94)
    public var isAutomaticInk: Bool { self == .black || self == .inkOnDark }
    /// Rec. 709 relative luminance of the sRGB components, 0...1.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public struct Style: Codable, Equatable, Sendable {
    public var stroke: RGBA = .black
    public var fill: RGBA = .clear
    public var strokeWidth: Double = 2
    /// 0 = precise geometry, 1 = hand-drawn, 2 = very sketchy.
    public var roughness: Double = 1
    public var fontSize: Double = 18
    public init() {}
}

public enum ElementKind: String, Codable, Sendable {
    case rectangle, ellipse, diamond, text, connector, freehand
}

/// A point inside a freehand stroke, normalized to the element's frame (0...1 on each axis),
/// so moving and resizing the element needs no special handling.
public struct StrokePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Layer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var visible: Bool
    public var locked: Bool
    public init(id: UUID = UUID(), name: String, visible: Bool = true, locked: Bool = false) {
        self.id = id; self.name = name; self.visible = visible; self.locked = locked
    }
}

public struct Element: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ElementKind
    public var x, y, width, height: Double
    public var style: Style
    /// Fixed per element so rough strokes stay stable across redraws and drags.
    public var seed: UInt32
    public var layerID: UUID
    public var text: String?
    /// Only set for `.connector`. Endpoints are bindings, never stored geometry.
    public var connector: ConnectorData?
    /// Elements sharing a `groupID` select and move together. Groups are flat (no nesting).
    public var groupID: UUID?
    /// Only set for `.freehand`. Raw pen samples; superseded by `path` once the stroke is committed.
    public var points: [StrokePoint]?
    /// Only set for `.freehand`. Fitted cubic Béziers as flat normalized `x, y` pairs:
    /// the start point, then `c1, c2, end` per segment (`2 + 6n` numbers).
    public var path: [Double]?

    public init(id: UUID = UUID(), kind: ElementKind, frame: CGRect, style: Style = Style(),
                seed: UInt32 = .random(in: 1...UInt32.max), layerID: UUID, text: String? = nil,
                connector: ConnectorData? = nil, groupID: UUID? = nil, points: [StrokePoint]? = nil) {
        self.groupID = groupID; self.points = points
        self.id = id; self.kind = kind
        self.x = frame.origin.x; self.y = frame.origin.y
        self.width = frame.width; self.height = frame.height
        self.style = style; self.seed = seed; self.layerID = layerID; self.text = text; self.connector = connector
    }

    public var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.origin.x; y = newValue.origin.y; width = newValue.width; height = newValue.height }
    }
}

/// Array order of `elements` is z-order, back to front.
public struct DottieDocument: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var layers: [Layer]
    public var elements: [Element]

    public init(layers: [Layer]? = nil, elements: [Element] = []) {
        self.layers = layers ?? [Layer(name: "Layer 1")]
        self.elements = elements
    }

    public func element(at point: CGPoint) -> Element? {
        elements.last { e in
            guard let layer = layers.first(where: { $0.id == e.layerID }), layer.visible, !layer.locked else { return false }
            if e.kind == .connector { return Connector.distance(from: point, to: e, in: self) <= 6 }
            return e.frame.insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    /// Removes elements; connectors bound to a removed shape keep their last position as free points.
    public mutating func remove(_ ids: Set<UUID>) {
        for i in elements.indices where elements[i].kind == .connector && !ids.contains(elements[i].id) {
            guard var c = elements[i].connector else { continue }
            let (s, e) = Connector.endpoints(of: elements[i], in: self)
            if let id = c.start.elementID, ids.contains(id) { c.start = .free(s) }
            if let id = c.end.elementID, ids.contains(id) { c.end = .free(e) }
            elements[i].connector = c
        }
        elements.removeAll { ids.contains($0.id) }
        // Drop connectors that lost both ends to deleted shapes? Keep them: they're free-floating arrows now.
    }

    /// Copy with every automatic-ink stroke replaced by `ink`, for display on a dark canvas or export.
    /// Explicitly chosen colors are untouched.
    ///
    /// A light ink is not used on a light, mostly opaque fill (a pastel box on a dark canvas): that
    /// shape's outline and label stay dark so they remain readable.
    public func resolvingInk(to ink: RGBA) -> DottieDocument {
        var copy = self
        for i in copy.elements.indices where copy.elements[i].style.stroke.isAutomaticInk {
            let fill = copy.elements[i].style.fill
            let onLightFill = fill.a >= 0.5 && fill.luminance > 0.5
            copy.elements[i].style.stroke = (ink.luminance > 0.5 && onLightFill) ? .black : ink
        }
        return copy
    }

    /// Copy with every element's roughness forced (e.g. 0 for a clean render of a sketchy drawing).
    public func withRoughness(_ value: Double) -> DottieDocument {
        var copy = self
        for i in copy.elements.indices { copy.elements[i].style.roughness = value }
        return copy
    }

    // MARK: JSON (git-friendly: sorted keys, pretty, rounded floats)

    public func encoded() throws -> Data {
        var copy = self
        for i in copy.elements.indices {
            func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            copy.elements[i].x = r(copy.elements[i].x)
            copy.elements[i].y = r(copy.elements[i].y)
            copy.elements[i].width = r(copy.elements[i].width)
            copy.elements[i].height = r(copy.elements[i].height)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(copy)
    }

    public static func decode(_ data: Data) throws -> DottieDocument {
        try JSONDecoder().decode(DottieDocument.self, from: data)
    }
}
