import Foundation

// Checks an interactive page's wiring the way an author would want to hear about it: a condition reading a variable
// nothing sets (a typo, usually), a click setting one nothing reads, a metric comparison or gauge pointing at nothing.
// Tools append these to their results, so a mistake shows up when it's made, not in a screenshot later.

extension DiagramOps {
    /// Who reads each variable: one short description per condition.
    private static func readers(_ doc: DottieDocument) -> [String: [String]] {
        var out: [String: [String]] = [:]
        func name(_ e: Element) -> String { e.text.map { "\"\($0.components(separatedBy: "\n")[0])\"" } ?? e.anchor ?? e.kind.rawValue }
        func read(_ condition: String, _ what: String) {
            for n in PageState.names(in: condition) ?? [] where !(out[n]?.contains(what) ?? false) { out[n, default: []].append(what) }
        }
        for e in doc.elements {
            if let w = e.when { read(w, "\(name(e))'s when") }
            for o in e.overrides ?? [] { read(o.when, "an override on \(name(e))") }
        }
        for f in doc.flows ?? [] { if let w = f.when { read(w, "a flow's when") } }
        return out
    }

    /// The variables clicks set or flip, with the elements clicked.
    private static func setters(_ doc: DottieDocument) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in doc.elements {
            guard let c = e.click else { continue }
            let who = e.text.map { "\"\($0.components(separatedBy: "\n")[0])\"" } ?? e.anchor ?? e.kind.rawValue
            for n in Array((c.set ?? [:]).keys) + (c.toggle ?? []) { out[n, default: []].append(who) }
        }
        return out
    }

    /// The page's wiring problems, most likely mistakes first; at most `limit`.
    public static func stateWarnings(_ doc: DottieDocument, limit: Int = 8) -> [String] {
        var out: [String] = []
        let declared = Set((doc.variables ?? [:]).keys)
        let read = readers(doc), set = setters(doc)
        func similar(_ name: String, in names: [String]) -> String? {
            func plain(_ s: String) -> [Character] { Array(s.lowercased().replacingOccurrences(of: "_", with: "")) }
            let a = plain(name)
            guard a.count >= 3 else { return nil }
            // The closest name a slip away: case and underscores ignored, then at most two edits.
            var best: (name: String, d: Int)? = nil
            for n in names.sorted() where n != name {
                let d = distance(a, plain(n))
                if d <= 2, d < (best?.d ?? 3) { best = (n, d) }
            }
            return best?.name
        }
        let known = Array(declared.union(set.keys)).sorted()
        for (n, who) in read.sorted(by: { $0.key < $1.key }) where !declared.contains(n) && set[n] == nil {
            var line = "`\(n)` is read by \(who.prefix(2).joined(separator: " and "))\(who.count > 2 ? " and \(who.count - 2) more" : "")"
                + ", but no variable or click sets it, so it's always false"
            if let s = similar(n, in: known) { line += ". Did you mean `\(s)`?" }
            else if !known.isEmpty { line += ". Variables: " + known.prefix(8).joined(separator: ", ") }
            out.append(line)
        }
        for (n, who) in set.sorted(by: { $0.key < $1.key }) where read[n] == nil && !declared.contains(n) {
            var line = "Clicking \(who[0]) sets `\(n)`, which nothing reads"
            if let s = similar(n, in: Array(read.keys)) { line += ". Did you mean `\(s)`?" }
            out.append(line)
        }
        // Metric comparisons and gauges.
        var anchors = Set<String>()
        for e in doc.elements { if let a = e.anchor { anchors.insert(a) } }
        let ids = Set(doc.elements.map(\.id)).union((doc.flows ?? []).map(\.id))
        func exists(_ target: String) -> Bool { anchors.contains(target) || UUID(uuidString: target).map(ids.contains) == true }
        var seen = Set<String>()
        for e in doc.elements {
            let conditions = (e.when.map { [$0] } ?? []) + (e.overrides ?? []).map(\.when)
            for c in conditions {
                for term in c.components(separatedBy: "||").flatMap({ $0.components(separatedBy: "&&") }) {
                    guard let m = PageState.metricTerm(term), !exists(m.target), seen.insert(m.target).inserted else { continue }
                    var line = "`\(m.metric)(\(m.target))` names no element's anchor (or element or flow id), so it never holds"
                    if let s = similar(m.target, in: Array(anchors)) { line += ". Did you mean `\(s)`?" }
                    out.append(line)
                }
            }
            if let w = e.when, PageState.mentionsMetric(w) {
                out.append("A when can't compare metrics, so \(e.text.map { "\"\($0)\"" } ?? "an element") is never drawn; use an override")
            }
            for o in e.overrides ?? [] where PageState.mentionsMetric(o.when) && o != o.looksOnly {
                out.append("The override `\(o.when)` compares a metric, so only its looks apply (not offline, cost, capacity, delay or reroute)")
            }
            if let g = e.gauge, !ids.contains(g.of) {
                out.append("A gauge (\(g.label ?? g.metric)) measures \(g.of.uuidString), which is no element or flow, so it shows a dash")
            }
        }
        return Array(out.prefix(limit))
    }

    /// Edit distance between two strings (Levenshtein).
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var prev = row[0]; row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let keep = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, prev + (ca == cb ? 0 : 1))
                prev = keep
            }
        }
        return row[b.count]
    }

    /// One line per variable: its starting value, what reads it and which clicks change it.
    public static func describeVariables(_ doc: DottieDocument) -> [String] {
        let read = readers(doc), set = setters(doc)
        let names = Set((doc.variables ?? [:]).keys).union(read.keys).union(set.keys)
        return names.sorted().map { n in
            var line = "\(n) (starts \(doc.variables?[n] ?? false))"
            let r = read[n] ?? [], s = set[n] ?? []
            line += r.isEmpty ? ": read by nothing" : ": read by " + r.prefix(4).joined(separator: ", ") + (r.count > 4 ? " and \(r.count - 4) more" : "")
            line += s.isEmpty ? "; no click changes it" : "; changed by clicking " + s.prefix(4).joined(separator: ", ")
            return line
        }
    }
}
