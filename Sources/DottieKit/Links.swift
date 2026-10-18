import Foundation
import CoreGraphics

/// Where an element's `url` leads, outside the drawing: a web or mail address, or another drawing.
public enum OutsideLink: Equatable, Sendable {
    /// An `http`, `https` or `mailto` address (`ClickAction.allowed`), opened in the browser or mail app.
    case web(String)
    /// Another `.dottie` file: `path` relative to the drawing that links to it (or absolute), and the anchor or page
    /// name after a `#` to go to once it is open.
    case drawing(path: String, anchor: String?)

    /// The link `string` names, or nil when it is neither an allowed web address nor a path to a `.dottie` file.
    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        if let web = ClickAction.allowed(s) { self = .web(web); return }
        // Anything else with a scheme (`javascript:`, `file:`, `data:`) is refused; a drive-letter-free path has none.
        if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") { return nil }
        let hash = s.firstIndex(of: "#")
        let path = String(s[..<(hash ?? s.endIndex)])
        guard path.lowercased().hasSuffix(".dottie"), path.count > ".dottie".count else { return nil }
        let fragment = hash.map { String(s[s.index(after: $0)...]) }
        let anchor = fragment.map { $0.removingPercentEncoding ?? $0 }.flatMap { $0.isEmpty ? nil : $0 }
        self = .drawing(path: path.removingPercentEncoding ?? path, anchor: anchor)
    }

    /// The link written back as an element's `url`.
    public var string: String {
        switch self {
        case .web(let s): s
        case .drawing(let path, let anchor): path + (anchor.map { "#" + $0 } ?? "")
        }
    }

    /// The address a page may open, for a web link.
    public var webAddress: String? { if case .web(let s) = self { s } else { nil } }

    /// A link to the drawing at `target` from the drawing at `base`: relative to it when they share more than the
    /// root folder, so the two can move together, else absolute (and absolute when `base` is unsaved). `anchor` is
    /// where to go once it is open.
    public static func drawing(at target: URL, from base: URL?, anchor: String? = nil) -> OutsideLink {
        let anchor = anchor.flatMap { $0.isEmpty ? nil : $0 }
        func canonical(_ u: URL) -> URL { u.standardizedFileURL.resolvingSymlinksInPath() }
        guard let base else { return .drawing(path: canonical(target).path, anchor: anchor) }
        let from = canonical(base).deletingLastPathComponent().pathComponents
        let to = canonical(target).pathComponents
        var shared = 0
        while shared < min(from.count, to.count), from[shared] == to[shared] { shared += 1 }
        guard shared > 1 else { return .drawing(path: canonical(target).path, anchor: anchor) }
        let up = Array(repeating: "..", count: from.count - shared)
        return .drawing(path: (up + to[shared...]).joined(separator: "/"), anchor: anchor)
    }

    /// The file a drawing link names, resolved against `base`, the file of the drawing that links to it. A relative
    /// path with no `base` (an unsaved drawing) leads nowhere.
    public func fileURL(relativeTo base: URL?) -> URL? {
        guard case .drawing(let path, _) = self else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        guard let base else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
    }
}

/// What a drawing link's `#name` finds in the drawing it opens.
public enum LinkDestination: Equatable, Sendable {
    case element(UUID)
    case page(UUID)
}

extension Element {
    /// `url` read as a link, if it is one a drawing may follow.
    public var outsideLink: OutsideLink? { url.flatMap(OutsideLink.init) }
}

extension DottieDocument {
    /// Points every element in `ids` at `url` (a web address or another drawing), or clears it when nil or empty.
    /// An element links to one place, so this clears their `link` to an element.
    public mutating func setURL(_ ids: Set<UUID>, to url: String?) throws {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var value: String?
        if !trimmed.isEmpty {
            guard let link = OutsideLink(trimmed) else {
                throw OpsError.invalid("A link must start with http://, https:// or mailto:, or name a .dottie file, got '\(trimmed)'")
            }
            value = link.string
        }
        for i in elements.indices where ids.contains(elements[i].id) {
            elements[i].url = value
            if value != nil { elements[i].link = nil }
        }
    }
}

extension DottieFile {
    /// Where a drawing link's `#name` goes in this file: the shape with that anchor (an exact match first, then one
    /// that differs only in case, in tab order), else the page with that name or number. nil when nothing matches.
    public func destination(_ name: String) -> LinkDestination? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let shapes = pages.flatMap { $0.elements.filter { $0.kind != .connector } }
        if let e = shapes.first(where: { $0.anchor == name }) { return .element(e.id) }
        if let e = shapes.first(where: { $0.anchor?.caseInsensitiveCompare(name) == .orderedSame }) { return .element(e.id) }
        return pageIndex(matching: name).map { .page(pages[$0].id) }
    }

    /// Every anchored shape, page by page in tab order and then by drawing order: the drawing's table of contents.
    public var anchors: [(page: UUID, element: UUID, name: String)] {
        pages.flatMap { p in
            p.orderedElements.compactMap { e in
                guard e.kind != .connector, let a = e.anchor, !a.isEmpty else { return nil }
                return (p.id, e.id, a)
            }
        }
    }
}

extension Exporter {
    /// The page as a still is drawn, with its symbol copies kept whole: where its links' click areas go in a PDF.
    static func linkLayout(_ doc: DottieDocument) -> DottieDocument {
        guard let tl = doc.timeline else { return doc }
        return doc.posed(at: tl.poster ?? tl.duration)
    }

    /// Adds `doc`'s links to the PDF page being drawn into `ctx`, whose drawing fills a page of `b`'s size at scale 1:
    /// web links open their address, and links to `targets` (the elements this PDF holds that something links to)
    /// jump to the named destination the target's page defines with `addLinkDestinations`.
    static func addLinks(_ doc: DottieDocument, bounds b: CGRect, targets: Set<UUID>, in ctx: CGContext) {
        let d = linkLayout(doc)
        let visible = Set(d.layers.filter(\.visible).map(\.id))
        let index = d.elementIndex
        for e in d.elements where visible.contains(e.layerID) && (e.style.opacity ?? 1) > 0 {
            let r = e.kind == .connector ? Connector.bounds(of: e, in: d, index: index) : e.rotatedBounds
            let area = pdfRect(r, in: b)
            if let target = e.link, targets.contains(target) {
                ctx.setDestination(target.uuidString as CFString, for: area)
            } else if e.link == nil, let web = e.outsideLink?.webAddress, let url = URL(string: web) {
                ctx.setURL(url as CFURL, for: area)
            }
        }
    }

    /// Names the place each of `targets` on this page is, so links elsewhere in the PDF can jump to it: the top-left
    /// of the target with its group, as following a link in the app shows it.
    static func addLinkDestinations(_ doc: DottieDocument, bounds b: CGRect, targets: Set<UUID>, in ctx: CGContext) {
        let d = linkLayout(doc)
        for e in d.elements where targets.contains(e.id) {
            guard let r = d.linkBounds(to: e.id) else { continue }
            ctx.addDestination(e.id.uuidString as CFString, at: CGPoint(x: r.minX - b.minX, y: b.height - (r.minY - b.minY)))
        }
    }

    /// `r`, in drawing coordinates (y down), as a rectangle on a PDF page showing `b` at scale 1 (y up).
    static func pdfRect(_ r: CGRect, in b: CGRect) -> CGRect {
        CGRect(x: r.minX - b.minX, y: b.height - (r.maxY - b.minY), width: r.width, height: r.height)
    }

    /// The elements links can jump to in a PDF of `pages`: shapes on visible layers that something links to.
    static func linkTargets(in pages: [DottieDocument]) -> Set<UUID> {
        let wanted = Set(pages.flatMap { $0.elements.compactMap(\.link) })
        guard !wanted.isEmpty else { return [] }
        var out = Set<UUID>()
        for p in pages {
            let visible = Set(p.layers.filter(\.visible).map(\.id))
            for e in p.elements where wanted.contains(e.id) && e.kind != .connector && visible.contains(e.layerID) { out.insert(e.id) }
        }
        return out
    }
}
