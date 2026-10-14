import Foundation

/// A `.dottie` file: one or more pages, shown as tabs. Element ids are unique across the whole file,
/// which is what lets a link point at a shape on another page.
public struct DottieFile: Codable, Equatable, Sendable {
    public var version: Int = 2
    /// Never empty. Array order is tab order.
    public var pages: [DottieDocument]

    public init(pages: [DottieDocument] = [DottieDocument()]) {
        self.pages = pages.isEmpty ? [DottieDocument()] : pages
    }

    private enum CodingKeys: String, CodingKey { case version, pages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        pages = try c.decode([DottieDocument].self, forKey: .pages)
        guard !pages.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .pages, in: c, debugDescription: "A drawing needs at least one page")
        }
        guard Set(pages.map(\.id)).count == pages.count else {
            throw DecodingError.dataCorruptedError(forKey: .pages, in: c, debugDescription: "Two pages share an id")
        }
    }

    // MARK: Lookup

    public func index(of pageID: UUID) -> Int? { pages.firstIndex { $0.id == pageID } }

    public func page(_ id: UUID) -> DottieDocument? { pages.first { $0.id == id } }

    /// The page holding element `id`.
    public func pageIndex(containing id: UUID) -> Int? {
        pages.firstIndex { $0.elements.contains { $0.id == id } }
    }

    /// A page by name (any case), or by its 1-based position when `spec` is a number no page is named.
    public func pageIndex(matching spec: String) -> Int? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if let i = pages.firstIndex(where: { $0.name.caseInsensitiveCompare(s) == .orderedSame }) { return i }
        if let n = Int(s), pages.indices.contains(n - 1) { return n - 1 }
        return nil
    }

    /// Where each followable link target lives: shapes on visible layers, by element id, to their page id.
    public var linkTargetPages: [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for p in pages {
            let visible = Set(p.layers.filter(\.visible).map(\.id))
            for e in p.elements where e.kind != .connector && visible.contains(e.layerID) { out[e.id] = p.id }
        }
        return out
    }

    // MARK: Editing pages

    /// Replaces the page with the same id. False when there is none.
    @discardableResult
    public mutating func replace(_ page: DottieDocument) -> Bool {
        guard let i = index(of: page.id) else { return false }
        pages[i] = page
        return true
    }

    /// "Page N" for the smallest N no page is called.
    public func nextPageName() -> String {
        let names = Set(pages.map { $0.name.lowercased() })
        var n = pages.count + 1
        for k in 1...(pages.count + 1) where !names.contains("page \(k)") { n = k; break }
        return "Page \(n)"
    }

    /// `base`, or `base 2`, `base 3`… if a page other than `except` already has that name.
    private func uniqueName(_ base: String, except: UUID? = nil) -> String {
        let names = Set(pages.filter { $0.id != except }.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        var n = 2
        while names.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Adds an empty page after `after` (at the end when nil or missing). Returns its id.
    @discardableResult
    public mutating func addPage(name: String? = nil, after: UUID? = nil) -> UUID {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let page = DottieDocument(name: trimmed.isEmpty ? nextPageName() : uniqueName(trimmed))
        let at = after.flatMap(index(of:)).map { $0 + 1 } ?? pages.endIndex
        pages.insert(page, at: at)
        return page.id
    }

    /// Removes a page; the last one cannot go. Links into it become broken, as for deleted shapes.
    @discardableResult
    public mutating func removePage(_ id: UUID) -> Bool {
        guard pages.count > 1, let i = index(of: id) else { return false }
        pages.remove(at: i)
        return true
    }

    public mutating func movePage(_ id: UUID, to destination: Int) {
        guard let i = index(of: id) else { return }
        let page = pages.remove(at: i)
        pages.insert(page, at: min(max(destination, 0), pages.endIndex))
    }

    public mutating func renamePage(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let i = index(of: id), !trimmed.isEmpty, trimmed != pages[i].name else { return }
        pages[i].name = uniqueName(trimmed, except: id)
    }

    /// Copies a page next to itself with fresh element and group ids, so ids stay unique across the file.
    /// Connectors and links within the page follow the copies; links to other pages are kept as they are.
    @discardableResult
    public mutating func duplicatePage(_ id: UUID) -> UUID? {
        guard let i = index(of: id) else { return nil }
        var copy = pages[i]
        copy.id = UUID()
        copy.name = uniqueName(pages[i].name + " copy")
        var ids: [UUID: UUID] = [:], groups: [UUID: UUID] = [:]
        for e in copy.elements { ids[e.id] = UUID() }
        for k in copy.elements.indices {
            var e = copy.elements[k]
            e.id = ids[e.id]!
            if let g = e.groupID {
                let n = groups[g] ?? UUID()
                groups[g] = n
                e.groupID = n
            }
            if let t = e.link { e.link = ids[t] ?? t }
            if var c = e.connector {
                if let s = c.start.elementID { c.start.elementID = ids[s] ?? s }
                if let t = c.end.elementID { c.end.elementID = ids[t] ?? t }
                e.connector = c
            }
            copy.elements[k] = e
        }
        pages.insert(copy, at: i + 1)
        return copy.id
    }

    // MARK: JSON (git-friendly: sorted keys, pretty, rounded floats)

    public func encoded() throws -> Data {
        var copy = self
        copy.pages = pages.map(\.rounded)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try enc.encode(copy)
    }

    public static func decode(_ data: Data) throws -> DottieFile {
        try JSONDecoder().decode(DottieFile.self, from: data)
    }
}
