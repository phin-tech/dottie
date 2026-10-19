import Foundation
import CoreGraphics

/// Reads Excalidraw scenes (`.excalidraw`) and libraries (`.excalidrawlib`). Shapes, text, arrows
/// (bound arrows stay attached), lines and freehand strokes come across with their look: stroke and fill
/// colors, hatching, dashes, width, roughness, rotation, opacity and groups. Images, frames and embeds
/// are skipped, and rounded rectangle corners become square.
public enum ExcalidrawImporter {
    public struct Item: Sendable {
        public var name: String?
        /// Positioned with the top-left corner at the origin.
        public var elements: [Element]
        public var size: CGSize
    }

    public enum ImportError: Error, Equatable { case notExcalidraw, empty }

    /// A scene is one item; a library is one item per library entry.
    public static func importItems(from data: Data, layerID: UUID) throws -> [Item] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String, type.hasPrefix("excalidraw") else { throw ImportError.notExcalidraw }
        var groups: [(name: String?, raw: [[String: Any]])] = []
        if type == "excalidrawlib" {
            if let v2 = root["libraryItems"] as? [[String: Any]] {
                for (i, entry) in v2.enumerated() {
                    guard let els = entry["elements"] as? [[String: Any]] else { continue }
                    groups.append((entry["name"] as? String ?? "Item \(i + 1)", els))
                }
            } else if let v1 = root["library"] as? [[[String: Any]]] {
                for (i, els) in v1.enumerated() { groups.append(("Item \(i + 1)", els)) }
            }
        } else if let els = root["elements"] as? [[String: Any]] {
            groups.append((nil, els))
        }
        let items = groups.compactMap { g -> Item? in
            var els = convert(g.raw, layerID: layerID)
            guard !els.isEmpty else { return nil }
            let box = StencilLibrary.normalizeToOrigin(&els)
            return Item(name: g.name, elements: els, size: box.size)
        }
        guard !items.isEmpty else { throw ImportError.empty }
        return items
    }

    // MARK: Conversion

    private static func num(_ v: Any?) -> Double? {
        (v as? NSNumber).map(\.doubleValue)
    }

    private static func color(_ v: Any?, opacity: Double) -> RGBA? {
        guard let s = v as? String, s != "transparent" else { return nil }
        if s.lowercased() == "#1e1e1e" || s.lowercased() == "#000000" || s.lowercased() == "#000" {
            var c = RGBA.black; c.a *= opacity; return c == RGBA.black ? .black : c
        }
        guard var c = Colors.parse(s, current: .black) else { return nil }
        c.a *= opacity
        return c
    }

    private static func convert(_ raw: [[String: Any]], layerID: UUID) -> [Element] {
        let live = raw.filter { ($0["isDeleted"] as? Bool) != true }
        var ids: [String: UUID] = [:]
        for r in live { if let id = r["id"] as? String { ids[id] = UUID() } }
        var groupIDs: [String: UUID] = [:]

        // Text bound to a container becomes that container's label.
        var labels: [String: String] = [:]
        var consumed = Set<String>()
        for r in live where (r["type"] as? String) == "text" {
            if let c = r["containerId"] as? String, ids[c] != nil, let t = r["text"] as? String, let id = r["id"] as? String {
                labels[c] = t; consumed.insert(id)
            }
        }

        var out: [Element] = []
        for r in live {
            guard let type = r["type"] as? String, let sid = r["id"] as? String, let id = ids[sid],
                  !consumed.contains(sid) else { continue }
            let x = num(r["x"]) ?? 0, y = num(r["y"]) ?? 0
            let w = num(r["width"]) ?? 0, h = num(r["height"]) ?? 0
            let opacity = min(max((num(r["opacity"]) ?? 100) / 100, 0), 1)

            var st = Style()
            st.stroke = color(r["strokeColor"], opacity: opacity) ?? .clear
            st.fill = color(r["backgroundColor"], opacity: opacity) ?? .clear
            switch r["fillStyle"] as? String {
            case "hachure", "zigzag": st.fillStyle = .hachure
            case "cross-hatch": st.fillStyle = .crossHatch
            default: st.fillStyle = .solid
            }
            switch r["strokeStyle"] as? String {
            case "dashed": st.dash = .dashed
            case "dotted": st.dash = .dotted
            default: st.dash = .solid
            }
            st.strokeWidth = max(0.5, num(r["strokeWidth"]) ?? 2)
            st.roughness = min(max(num(r["roughness"]) ?? 1, 0), 3)
            st.fontSize = num(r["fontSize"]) ?? 18

            var group: UUID?
            if let gids = r["groupIds"] as? [String], let outer = gids.last {
                group = groupIDs[outer] ?? { let g = UUID(); groupIDs[outer] = g; return g }()
            }
            let seed = UInt32(truncatingIfNeeded: Int(num(r["seed"]) ?? 1)) | 1
            let angle = num(r["angle"]) ?? 0

            func base(_ kind: ElementKind, _ frame: CGRect, text: String? = nil) -> Element {
                var e = Element(id: id, kind: kind, frame: frame, style: st, seed: seed, layerID: layerID,
                                text: text, groupID: group)
                if angle != 0 { e.rotation = angle }
                return e
            }
            let frame = CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))
            let pts: [CGPoint] = (r["points"] as? [[Double]] ?? []).compactMap {
                $0.count >= 2 ? CGPoint(x: x + $0[0], y: y + $0[1]) : nil
            }

            switch type {
            case "rectangle": out.append(base(.rectangle, frame, text: labels[sid]))
            case "diamond": out.append(base(.diamond, frame, text: labels[sid]))
            case "ellipse": out.append(base(.ellipse, frame, text: labels[sid]))
            case "text":
                var t = base(.text, frame, text: r["text"] as? String ?? "")
                t.style.fill = .clear
                out.append(t)
            case "arrow", "line":
                guard pts.count >= 2 else { continue }
                let isArrow = type == "arrow"
                let closed = !isArrow && pts.count > 2 && pts.first == pts.last
                if !isArrow, pts.count > 2 {
                    // A polyline or polygon is a shape, not a connector.
                    let p = CGMutablePath()
                    p.addLines(between: pts)
                    if closed { p.closeSubpath() }
                    if var e = Element.shape(p, style: st, seed: seed, layerID: layerID, groupID: group) {
                        e.id = id
                        if angle != 0 { e.rotation = angle }
                        out.append(e)
                    }
                    continue
                }
                func endpoint(_ key: String, _ p: CGPoint) -> Endpoint {
                    if let b = r[key] as? [String: Any], let target = b["elementId"] as? String, let tid = ids[target] {
                        return .bound(tid)
                    }
                    return .free(p)
                }
                func head(_ key: String, default d: Arrowhead) -> Arrowhead {
                    guard let v = r[key], !(v is NSNull) else { return key == "endArrowhead" && r[key] == nil ? d : .none }
                    switch v as? String {
                    case "arrow": return .arrow
                    case "triangle", "triangle_outline": return .triangle
                    case "dot", "circle", "circle_outline": return .dot
                    case "bar": return .bar
                    default: return .arrow
                    }
                }
                var c = ConnectorData(start: endpoint("startBinding", pts[0]), end: endpoint("endBinding", pts[pts.count - 1]))
                c.startHead = head("startArrowhead", default: .none)
                c.endHead = isArrow ? head("endArrowhead", default: .arrow) : .none
                if isArrow, (r["elbowed"] as? Bool) == true { c.routing = .elbow }
                else if isArrow, r["roundness"] is [String: Any], pts.count >= 3 { c.routing = .curved }
                // The points between an arrow's ends are its bends.
                if isArrow, pts.count > 2 { c.waypoints = pts[1..<(pts.count - 1)].map(Waypoint.init) }
                var e = Element(id: id, kind: .connector, frame: .zero, style: st, seed: seed, layerID: layerID,
                                text: labels[sid], connector: c, groupID: group)
                e.style.fill = .clear
                out.append(e)
            case "freedraw":
                guard pts.count >= 2 else { continue }
                let p = CGMutablePath()
                p.addLines(between: pts)
                var line = st; line.fill = .clear
                if var e = Element.shape(p, style: line, seed: seed, layerID: layerID, groupID: group) {
                    e.id = id
                    out.append(e)
                }
            default:
                continue // image, frame, embeddable, iframe
            }
        }
        return out
    }
}
