import Foundation
import CoreGraphics

/// A drawing tool an extension declares with `extension.tool(...)`. Its `draw` function lives in the extension's
/// JavaScript; this names it. `icon` is an SF Symbol name for the toolbar.
public struct ToolDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var icon: String?
}

/// A press and drag with an extension tool so far, as its `draw` function sees it: every point since the press, in
/// canvas points, and whether the button has been let go.
public struct ToolGesture: Equatable, Sendable {
    public var points: [CGPoint]
    public var done: Bool
    public var shift: Bool
    public var option: Bool

    public init(points: [CGPoint], done: Bool, shift: Bool = false, option: Bool = false) {
        self.points = points; self.done = done; self.shift = shift; self.option = option
    }

    var bridged: [String: Any] {
        ["points": points.map { ["x": Double($0.x), "y": Double($0.y)] }, "done": done, "shift": shift, "option": option]
    }
}

/// One element a tool's `draw` returned: a path in canvas points, or a rectangle, ellipse or diamond. Colors are
/// `#rrggbb` (or `#rrggbbaa`) or `"none"`; anything left out comes from the style new shapes get.
public struct DrawnElement: Decodable, Equatable, Sendable {
    public var kind: String
    public var subpaths: [Sub]?
    public var x, y, width, height: Double?
    public var text: String?
    public var fill: String?
    public var stroke: String?
    public var strokeWidth: Double?
    public var fillStyle: String?
    public var roughness: Double?

    public struct Sub: Decodable, Equatable, Sendable {
        public var closed: Bool
        public var coords: [Double]
    }

    /// The most elements one `draw` may return.
    public static let limit = 500
    /// How far from the origin a drawn point may be, and how wide or tall an element may get, in points. A tool
    /// draws near the pointer; past these, filling and flattening work grows without bound (or overflows).
    public static let reach = 100_000.0
    public static let span = 20_000.0
    /// The longest text a drawn shape may hold.
    public static let textLimit = 10_000

    /// The elements to add for what `draw` returned, on `layerID` in `style` (with the element's own colors over it).
    /// `seed` is the first element's, the rest count up from it, so a drag's previews keep one sketchy wobble.
    public static func elements(_ drawn: [DrawnElement], style: Style, layerID: UUID, seed: UInt32) throws -> [Element] {
        guard drawn.count <= limit else { throw ExtensionError.failed("draw returned more than \(limit) elements") }
        return try drawn.enumerated().map { i, d in try d.element(style: style, layerID: layerID, seed: seed &+ UInt32(i)) }
    }

    func element(style base: Style, layerID: UUID, seed: UInt32) throws -> Element {
        var style = base
        func color(_ s: String?, _ what: String) throws -> RGBA? {
            guard let s else { return nil }
            if s == "none" { return .clear }
            guard let c = RGBA(hex: s) else { throw ExtensionError.failed("draw: \(what) must be a hex color like #ffcc00 or \"none\", got '\(s)'") }
            return c
        }
        if let c = try color(fill, "fill") { style.fill = c }
        if let c = try color(stroke, "stroke") { style.stroke = c }
        if let w = strokeWidth {
            guard w.isFinite, (0...24).contains(w) else { throw ExtensionError.failed("draw: strokeWidth must be 0...24") }
            style.strokeWidth = w
        }
        if let f = fillStyle {
            guard let fs = FillStyle(rawValue: f) else {
                throw ExtensionError.failed("draw: fillStyle must be one of \(FillStyle.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            style.fillStyle = fs
        }
        if let r = roughness {
            guard r.isFinite, (0...2).contains(r) else { throw ExtensionError.failed("draw: roughness must be 0...2") }
            style.roughness = r
        }
        switch kind {
        case "path":
            guard let subpaths, !subpaths.isEmpty else { throw ExtensionError.failed("draw: a path needs subpaths") }
            let path = CGMutablePath()
            for sub in subpaths {
                let c = sub.coords
                guard c.count >= 8, (c.count - 2) % 6 == 0, c.allSatisfy(\.isFinite) else {
                    throw ExtensionError.failed("draw: a subpath needs 2 + 6n finite coordinates (start, then c1, c2, end per segment)")
                }
                guard c.allSatisfy({ abs($0) <= Self.reach }) else {
                    throw ExtensionError.failed("draw: path coordinates must be within \(Int(Self.reach)) points of the origin")
                }
                path.move(to: CGPoint(x: c[0], y: c[1]))
                for k in stride(from: 2, to: c.count, by: 6) {
                    path.addCurve(to: CGPoint(x: c[k + 4], y: c[k + 5]), control1: CGPoint(x: c[k], y: c[k + 1]),
                                  control2: CGPoint(x: c[k + 2], y: c[k + 3]))
                }
                if sub.closed { path.closeSubpath() }
            }
            let box = path.boundingBox // control points included, so it holds the curve
            guard box.width <= Self.span, box.height <= Self.span else {
                throw ExtensionError.failed("draw: a path may be at most \(Int(Self.span)) points wide and tall")
            }
            guard let e = Element.shape(path, style: style, seed: seed, layerID: layerID) else {
                throw ExtensionError.failed("draw: the path is empty")
            }
            return e
        case "rectangle", "ellipse", "diamond":
            guard let x, let y, let width, let height, [x, y, width, height].allSatisfy(\.isFinite), width >= 0, height >= 0 else {
                throw ExtensionError.failed("draw: a \(kind) needs finite x, y, width and height")
            }
            guard abs(x) <= Self.reach, abs(y) <= Self.reach, width <= Self.span, height <= Self.span else {
                throw ExtensionError.failed("draw: a \(kind) must lie within \(Int(Self.reach)) points of the origin and be at most \(Int(Self.span)) points wide and tall")
            }
            guard (text?.count ?? 0) <= Self.textLimit else {
                throw ExtensionError.failed("draw: text may be at most \(Self.textLimit) characters")
            }
            return Element(kind: ElementKind(rawValue: kind)!, frame: CGRect(x: x, y: y, width: max(width, 1), height: max(height, 1)),
                           style: style, seed: seed, layerID: layerID, text: text)
        default:
            throw ExtensionError.failed("draw: kind must be path, rectangle, ellipse or diamond, got '\(kind)'")
        }
    }
}

extension ExtensionRuntime {
    public func tool(named id: String) -> ToolDefinition? { tools.first { $0.id == id } }

    /// Runs a tool's `draw` on the gesture so far and returns the elements it asks for, not yet placed on a page.
    public func draw(tool id: String, _ gesture: ToolGesture) throws -> [DrawnElement] {
        guard tool(named: id) != nil else { throw ExtensionError.noSuchTool(id) }
        struct Out: Decodable { var elements: [DrawnElement] }
        guard let raw = try call("__drawTool", [id, gesture.bridged]), let data = raw.data(using: .utf8) else {
            throw ExtensionError.failed("draw: draw returned nothing")
        }
        do { return try JSONDecoder().decode(Out.self, from: data).elements }
        catch { throw ExtensionError.failed("draw: draw must return { elements: [...] }: \(error.localizedDescription)") }
    }
}
