import SwiftUI
import AppKit
import DottieKit

/// The selection's link out of the drawing: a web address or another drawing. Committed on Return or when the field
/// loses focus, so typing is one undo step; a link Dottie can't follow beeps and is put back.
struct LinkURLField: View {
    /// The link every selected element shares; nil when there is none, or they differ (`mixed`).
    var value: String?
    var mixed: Bool
    /// Changes when the selection does, so the field shows the new selection's link.
    var identity: Set<UUID>
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Opens", text: $text, prompt: Text(mixed ? "Several links" : "https://… or other.dottie#anchor"))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, now in if !now { save() } }
            .onAppear { text = value ?? "" }
            .onChange(of: identity) { _, _ in text = value ?? "" }
            .onChange(of: value) { _, v in if !focused { text = v ?? "" } }
            .help("A web or mail link, or another drawing (a path from this one, with #anchor or #page to open it at). Replaces Jumps to")
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (value ?? "") else { return }
        if !trimmed.isEmpty, OutsideLink(trimmed) == nil {
            NSSound.beep()
            text = value ?? ""
            return
        }
        commit(trimmed)
    }
}

/// Where in another drawing a link opens it: its start, one of its anchored shapes, or one of its pages. Read from
/// the file when the link changes; a drawing that can't be read offers nothing.
struct DrawingAnchorPicker: View {
    var link: OutsideLink
    var base: URL?
    var choose: (String?) -> Void
    @State private var places: (anchors: [String], pages: [String])?

    private var anchor: String? { if case .drawing(_, let a) = link { a } else { nil } }

    var body: some View {
        Group {
            if let places, !(places.anchors.isEmpty && places.pages.count < 2) {
                Picker("At", selection: Binding(get: { anchor ?? "" }, set: { choose($0.isEmpty ? nil : $0) })) {
                    Text("Start").tag("")
                    if let anchor, !places.anchors.contains(anchor), !places.pages.contains(anchor) {
                        Text(anchor + " (missing)").tag(anchor)
                    }
                    if !places.anchors.isEmpty {
                        Section("Anchors") { ForEach(places.anchors, id: \.self) { Text($0).tag($0) } }
                    }
                    if places.pages.count > 1 {
                        Section("Pages") { ForEach(places.pages, id: \.self) { Text($0).tag($0) } }
                    }
                }
            } else if places == nil, link.fileURL(relativeTo: base) == nil || OutsideLinks.isBroken(link, from: base) {
                Text(base == nil ? "Save this drawing to follow a link relative to it" : "No drawing there")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: link.fileURL(relativeTo: base)) { places = Self.read(link.fileURL(relativeTo: base)) }
    }

    /// The anchors and page names of the drawing at `url`, anchors once each in the order the file lists them.
    static func read(_ url: URL?) -> (anchors: [String], pages: [String])? {
        guard let url, let data = try? Data(contentsOf: url), let file = try? DottieFile.decode(data) else { return nil }
        var seen = Set<String>()
        let anchors = file.anchors.map(\.name).filter { seen.insert($0).inserted }
        return (anchors, file.pages.map(\.name))
    }
}

/// The Anchors tab: every anchored shape in the drawing, page by page, like a table of contents. A click goes there;
/// the context menu copies a link to it that another drawing can use.
struct AnchorsPanel: View {
    @ObservedObject var document: DrawingDocument
    var fileURL: URL?
    var onJump: (UUID) -> Void

    var body: some View {
        let anchors = document.file.anchors
        if anchors.isEmpty {
            Form {
                Text("Give a shape an anchor in the Behavior tab to list it here. Links from other drawings can open this one at it, as name.dottie#anchor.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        } else {
            List {
                ForEach(document.file.pages.filter { p in anchors.contains { $0.page == p.id } }) { page in
                    Section(page.name) {
                        ForEach(anchors.filter { $0.page == page.id }, id: \.element) { a in
                            Button { onJump(a.element) } label: {
                                Label(a.name, systemImage: "bookmark")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Go to \(a.name)")
                            .contextMenu {
                                Button("Go") { onJump(a.element) }
                                Button("Copy Link") { copyLink(a.name) }
                                    .disabled(fileURL == nil)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    /// Puts a link to the anchor on the pasteboard, as the drawing's full path and `#anchor`; pasted into another
    /// drawing's link field, it is written relative to that drawing.
    private func copyLink(_ anchor: String) {
        guard let fileURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(OutsideLink.drawing(at: fileURL, from: nil, anchor: anchor).string, forType: .string)
    }
}
