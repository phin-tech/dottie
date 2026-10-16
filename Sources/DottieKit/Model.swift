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

public enum FillStyle: String, Codable, Sendable, CaseIterable {
    case solid, hachure, crossHatch
    /// A dungeon floor: a solid fill ruled into square cells on a page-wide lattice, with Dyson-style
    /// hatching in the rock around it (see `DungeonGrid`).
    case grid
}
public enum DashStyle: String, Codable, Sendable, CaseIterable { case solid, dashed, dotted }

public struct Style: Codable, Equatable, Sendable {
    public var stroke: RGBA = .black
    public var fill: RGBA = .clear
    public var fillStyle: FillStyle = .solid
    public var strokeWidth: Double = 2
    public var dash: DashStyle = .solid
    /// 0 = precise geometry, 1 = hand-drawn, 2 = very sketchy.
    public var roughness: Double = 1
    /// Sideways bow of sketchy lines, independent of roughness. 0 is straight but shaky.
    public var bowing: Double = 1
    public var fontSize: Double = 18
    /// Cell size of a `.grid` fill in points; nil is `Style.defaultGridSize`.
    public var gridSize: Double?
    /// How opaque the whole element is, 0...1; nil is fully opaque. Keyable, so elements can fade.
    public var opacity: Double?
    /// How far into its dash pattern a dashed or dotted line starts, in points; nil is 0. Marching ants
    /// (`Track.march`) set it on every frame.
    public var dashOffset: Double?
    public init() {}

    public static let defaultGridSize = 50.0
    /// The `.grid` cell size actually drawn, never so small that the lines become a solid tint.
    public var cellSize: Double {
        get { max(8, gridSize ?? Style.defaultGridSize) }
        set { gridSize = newValue }
    }

    // Every field is optional on disk so hand- or agent-written files stay valid as the style grows.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? .black
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill) ?? .clear
        fillStyle = try c.decodeIfPresent(FillStyle.self, forKey: .fillStyle) ?? .solid
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 2
        dash = try c.decodeIfPresent(DashStyle.self, forKey: .dash) ?? .solid
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? 1
        bowing = try c.decodeIfPresent(Double.self, forKey: .bowing) ?? 1
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18
        gridSize = try c.decodeIfPresent(Double.self, forKey: .gridSize)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
        dashOffset = try c.decodeIfPresent(Double.self, forKey: .dashOffset).flatMap { $0.isFinite ? $0 : nil }
    }
}

public enum ElementKind: String, Codable, Sendable {
    case rectangle, ellipse, diamond, text, connector, freehand
    /// A closed or open compound Bézier shape (`subpaths`), as imported from SVG or a stencil.
    case path
    /// A sticky note: a filled card whose `text` is Markdown, laid out from the top left (see `Note`).
    case note
    /// A picture (`image`), drawn in its frame; outlined only when it has a visible stroke.
    case image
}

/// One contour of a `.path` element: cubic Béziers as flat `x, y` pairs normalized to the element's
/// frame (the start point, then `c1, c2, end` per segment: `2 + 6n` numbers). A straight line is a
/// segment whose control points sit on its end points.
public struct PathSubpath: Codable, Hashable, Sendable {
    public var closed: Bool
    public var coords: [Double]
    public init(closed: Bool, coords: [Double]) { self.closed = closed; self.coords = coords }
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
    /// Only set for `.path`. The shape's contours, filled together and stroked as one.
    public var subpaths: [PathSubpath]?
    /// Only for `.path`: fill with the even-odd rule (SVG's `fill-rule: evenodd`) instead of nonzero.
    public var evenOdd: Bool?
    /// Clockwise rotation in radians about the frame's center. nil is unrotated; connectors ignore it.
    public var rotation: Double?
    /// Another element this one jumps to when its link badge is clicked. May name an element that has since
    /// been deleted; such a link is shown as broken and comes back if the delete is undone.
    public var link: UUID?
    /// A hidden label for finding and linking to the element. Never drawn or exported.
    public var anchor: String?
    /// What clicking the element does when the drawing plays on the web (the HTML export and
    /// `<dottie-player>`). Every other export ignores it.
    public var click: ClickAction?
    /// How the element looks under the pointer, or with keyboard focus, when it is clickable on the web.
    public var hover: HoverLook?
    /// Only set for `.image`: the picture's bytes.
    public var image: EmbeddedImage?
    /// How much of the stroke is drawn, 0...1, in an animation frame (see `Keyframe.reveal`). Fill and label
    /// wait for the whole stroke; text types out. nil is fully drawn.
    public var reveal: Double?

    public init(id: UUID = UUID(), kind: ElementKind, frame: CGRect, style: Style = Style(),
                seed: UInt32 = .random(in: 1...UInt32.max), layerID: UUID, text: String? = nil,
                connector: ConnectorData? = nil, groupID: UUID? = nil, points: [StrokePoint]? = nil) {
        self.groupID = groupID; self.points = points
        self.id = id; self.kind = kind
        self.x = frame.origin.x; self.y = frame.origin.y
        self.width = frame.width; self.height = frame.height
        self.style = style; self.seed = seed; self.layerID = layerID; self.text = text; self.connector = connector
    }

    /// `rotation`, with nil read as 0.
    public var angle: Double { rotation ?? 0 }

    /// Maps a point from the element's own (unrotated) frame to the canvas.
    public func rotated(_ p: CGPoint) -> CGPoint { Element.rotate(p, about: CGPoint(x: frame.midX, y: frame.midY), by: angle) }
    /// Maps a canvas point into the element's own (unrotated) frame.
    public func unrotated(_ p: CGPoint) -> CGPoint { Element.rotate(p, about: CGPoint(x: frame.midX, y: frame.midY), by: -angle) }

    /// After resizing a rotated shape in its own axes (`resized`), slides the frame so the corner or edge
    /// at fractions (`fx`, `fy`) of the frame, which the user did not touch, stays put on the canvas.
    public static func reanchored(_ resized: CGRect, original: CGRect, angle: Double, fx: Double, fy: Double) -> CGRect {
        guard angle != 0 else { return resized }
        let oc = CGPoint(x: original.midX, y: original.midY)
        let pivot = CGPoint(x: original.minX + original.width * fx, y: original.minY + original.height * fy)
        let world = rotate(pivot, about: oc, by: angle)
        let c = CGPoint(x: resized.midX, y: resized.midY)
        let local = CGPoint(x: resized.minX + resized.width * fx, y: resized.minY + resized.height * fy)
        let off = rotate(CGPoint(x: local.x - c.x, y: local.y - c.y), about: .zero, by: angle)
        let center = CGPoint(x: world.x - off.x, y: world.y - off.y)
        return CGRect(x: center.x - resized.width / 2, y: center.y - resized.height / 2, width: resized.width, height: resized.height)
    }

    public static func rotate(_ p: CGPoint, about c: CGPoint, by a: Double) -> CGPoint {
        guard a != 0 else { return p }
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    /// Copy with automatic ink replaced by `ink`; a light ink is not used on a light, mostly opaque fill.
    /// Hatching leaves the page showing between its lines, so it never counts as a light fill.
    public func resolvingInk(to ink: RGBA) -> Element {
        guard style.stroke.isAutomaticInk else { return self }
        var copy = self
        let covers = style.fillStyle == .solid || style.fillStyle == .grid
        let onLightFill = covers && style.fill.a >= 0.5 && style.fill.luminance > 0.5
        copy.style.stroke = (ink.luminance > 0.5 && onLightFill) ? .black : ink
        return copy
    }

    /// Bounding box of the frame after rotation.
    public var rotatedBounds: CGRect {
        let r = frame
        guard angle != 0 else { return r }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(rotated)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    public var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.origin.x; y = newValue.origin.y; width = newValue.width; height = newValue.height }
    }
}

/// What clicking an element in a played drawing does: jump to a scene and play on from it (Flash's
/// `gotoAndPlay`), or open a link. A scene wins when both are set.
public struct ClickAction: Codable, Equatable, Sendable {
    /// The name of a scene (`Marker`) on the element's page.
    public var scene: String?
    /// A web or mail link, opened in a new tab. Only `http:`, `https:` and `mailto:` links are kept, since a
    /// drawing can play on someone else's site.
    public var url: String? { didSet { url = url.flatMap(Self.allowed) } }

    public init(scene: String? = nil, url: String? = nil) {
        self.scene = scene
        self.url = url.flatMap(Self.allowed)
    }

    private enum CodingKeys: String, CodingKey { case scene, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scene: try c.decodeIfPresent(String.self, forKey: .scene),
                  url: try c.decodeIfPresent(String.self, forKey: .url))
    }

    /// `url` trimmed, if it is a link a page may open.
    public static func allowed(_ url: String) -> String? {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = u.lowercased()
        guard ["http://", "https://", "mailto:"].contains(where: lower.hasPrefix), u.count > 7,
              !u.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return u
    }

    /// Nothing to do.
    public var isEmpty: Bool { (scene ?? "").isEmpty && url == nil }
}

/// The look of a clickable element under the pointer: the colors and opacity it takes; nil keeps its own.
public struct HoverLook: Codable, Equatable, Sendable {
    public var stroke, fill: RGBA?
    public var opacity: Double?
    public init(stroke: RGBA? = nil, fill: RGBA? = nil, opacity: Double? = nil) {
        self.stroke = stroke; self.fill = fill; self.opacity = opacity
    }

    /// `e` as it looks hovered.
    public func apply(to e: Element) -> Element {
        var e = e
        if let stroke { e.style.stroke = stroke }
        if let fill { e.style.fill = fill }
        if let opacity, opacity.isFinite { let o = min(max(opacity, 0), 1); e.style.opacity = o >= 1 ? nil : o }
        return e
    }

    public var isEmpty: Bool { stroke == nil && fill == nil && opacity == nil }
}

/// One page (a tab) of a drawing. Array order of `elements` is z-order, back to front.
/// A `.dottie` file is a `DottieFile`, which holds one or more of these.
public struct DottieDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layers: [Layer]
    public var elements: [Element]
    /// A `Theme` id (page color and ink); nil follows the system appearance and exports on white.
    public var theme: String?
    /// Ruler guides: x positions of vertical guides and y positions of horizontal ones.
    public var guidesX: [Double]?
    public var guidesY: [Double]?
    /// Locked guides still snap, but cannot be dragged or created from the rulers.
    public var guidesLocked: Bool?
    /// Keyframe animation over this page's elements (see `resolved(at:)`); nil is a still page.
    public var timeline: Timeline?

    public init(id: UUID = UUID(), name: String = "Page 1", layers: [Layer]? = nil, elements: [Element] = []) {
        self.id = id
        self.name = name
        self.layers = layers ?? [Layer(name: "Layer 1")]
        self.elements = elements
    }

    /// Elements by id, for passes that resolve many connectors at once.
    public var elementIndex: [UUID: Element] {
        Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func element(at point: CGPoint) -> Element? {
        let index = elements.contains { $0.kind == .connector } ? elementIndex : nil
        let open = Set(layers.filter { $0.visible && !$0.locked }.map(\.id))
        return orderedElements.last { e in
            guard open.contains(e.layerID) else { return false }
            if e.kind == .connector { return Connector.distance(from: point, to: e, in: self, index: index) <= 6 }
            return e.frame.insetBy(dx: -4, dy: -4).contains(e.unrotated(point))
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
        timeline?.tracks.removeAll { ids.contains($0.element) }
        // Drop connectors that lost both ends to deleted shapes? Keep them: they're free-floating arrows now.
    }

    /// Copy with every automatic-ink stroke replaced by `ink`, for display on a dark canvas or export.
    /// Explicitly chosen colors are untouched.
    ///
    /// A light ink is not used on a light, mostly opaque fill (a pastel box on a dark canvas): that
    /// shape's outline and label stay dark so they remain readable.
    public func resolvingInk(to ink: RGBA) -> DottieDocument {
        var copy = self
        for i in copy.elements.indices { copy.elements[i] = copy.elements[i].resolvingInk(to: ink) }
        return copy
    }

    /// Copy with every element's roughness forced (e.g. 0 for a clean render of a sketchy drawing).
    public func withRoughness(_ value: Double) -> DottieDocument {
        var copy = self
        for i in copy.elements.indices { copy.elements[i].style.roughness = value }
        return copy
    }

    // MARK: JSON (git-friendly: sorted keys, pretty, rounded floats)

    /// Frames rounded to hundredths, as they are saved.
    var rounded: DottieDocument {
        var copy = self
        for i in copy.elements.indices {
            func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            copy.elements[i].x = r(copy.elements[i].x)
            copy.elements[i].y = r(copy.elements[i].y)
            copy.elements[i].width = r(copy.elements[i].width)
            copy.elements[i].height = r(copy.elements[i].height)
        }
        return copy
    }

    /// This page alone as JSON. A `.dottie` file is `DottieFile.encoded()`.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(rounded)
    }

    public static func decode(_ data: Data) throws -> DottieDocument {
        try JSONDecoder().decode(DottieDocument.self, from: data)
    }
}
