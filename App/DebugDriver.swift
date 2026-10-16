#if DEBUG
import AppKit
import SwiftUI
import DottieKit

/// What a window exposes to the debug driver; ContentView registers it when it appears or becomes key.
struct DebugHooks {
    var document: DrawingDocument
    var undoManager: UndoManager?
    var editor: () -> EditorActions
    var playhead: () -> Double?
    var setPlayhead: (Double?) -> Void
    var playing: () -> Bool
    var setPlaying: (Bool) -> Void
    var selection: () -> Set<UUID>
    var setSelection: (Set<UUID>) -> Void
    var selectedKey: () -> KeyRef?
    var setSelectedKey: (KeyRef?) -> Void
    var editTimeline: (String, (inout Timeline) -> Void) -> Void
}

/// Drives a Debug build over the live socket so an agent can look at the real app without screen-recording
/// or accessibility permissions: the app renders its own window to a PNG, and commands set the playhead,
/// run Animate actions, select shapes and drag on the canvas. Client: `scripts/dottie-debug.py`.
@MainActor
final class DebugDriver {
    static let shared = DebugDriver()
    var front: DebugHooks?

    static let help = """
    state                        what the front window shows
    open <file.dottie>           open a document (give it a moment, then `state`)
    size <width> <height>        resize the front window's content
    snapshot <out.png> [canvas]  render the window (or just the canvas) to a PNG
    playhead <seconds|none>      move the playhead (paused there, the canvas poses that frame)
    play | pause | done          play, pause, or stop previewing
    select all|none|<text>       select shapes whose text contains <text>
    action <name> [arg]          newAnimation, removeAnimation, transition <popIn|...>, packet,
                                 build <popIn|drawIn|packets>, boil, settle, clearKeys, undo, redo
    drag <x1> <y1> <x2> <y2>     drag on the canvas, in canvas points (top-left origin)
    click <x> <y>                click on the canvas
    key <esc|delete|text>        send a key to the canvas
    keys <text>                  list the keys of the element whose text contains <text>
    keysel <text> <t>            select that element's key at <t> in the timeline (none: clear)
    keymove <text> <from> <to> [copy]   retime (or copy) a key, as dragging a diamond does
    keyease <text> <t> <ease>    set a key's ease: linear, easeIn, easeOut, easeInOut, hold
    keydel <text> <t>            delete a key
    menu [Top/Sub/...]           list the menu bar (or a menu); items read as disabled while the app is in
                                 the background, since commands follow the focused window
    quit                         quit this copy of the app (unsaved changes are discarded)
    """

    func handle(_ args: [String]) -> LiveResponse {
        guard let command = args.first else { return ok(Self.help) }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "help": return ok(Self.help)
            case "state": return ok(try state())
            case "open":
                let url = URL(fileURLWithPath: try arg(rest, 0, "path"))
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                return ok("opening \(url.path)")
            case "size":
                guard let w = Double(try arg(rest, 0, "width")), let h = Double(try arg(rest, 1, "height")) else {
                    throw DebugError("size takes two numbers")
                }
                try window().setContentSize(NSSize(width: w, height: h))
                return ok("resized to \(Int(w))x\(Int(h))")
            case "snapshot":
                let url = URL(fileURLWithPath: try arg(rest, 0, "output path"))
                let view: NSView = rest.count > 1 && rest[1] == "canvas" ? try canvas() : try window().contentView!.superview!
                return ok(try snapshot(view, to: url))
            case "playhead":
                let h = try hooks()
                let v = try arg(rest, 0, "seconds")
                h.setPlaying(false)
                h.setPlayhead(v == "none" ? nil : Double(v))
                return ok("playhead \(v)")
            case "play": try hooks().setPlaying(true); if try hooks().playhead() == nil { try hooks().setPlayhead(0) }; return ok("playing")
            case "pause": try hooks().setPlaying(false); return ok("paused")
            case "done": let h = try hooks(); h.setPlaying(false); h.setPlayhead(nil); return ok("editing")
            case "select": return ok(try select(rest.joined(separator: " ")))
            case "action": return ok(try action(rest))
            case "drag":
                let n = try rest.prefix(4).map { s -> CGFloat in
                    guard let v = Double(s) else { throw DebugError("drag takes four numbers") }
                    return CGFloat(v)
                }
                guard n.count == 4 else { throw DebugError("drag takes four numbers") }
                try drag(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]))
                return ok("dragged")
            case "click":
                guard let x = Double(try arg(rest, 0, "x")), let y = Double(try arg(rest, 1, "y")) else { throw DebugError("click takes two numbers") }
                try drag(CGPoint(x: x, y: y), CGPoint(x: x, y: y), steps: 0)
                return ok("clicked")
            case "key": return ok(try key(rest.joined(separator: " ")))
            case "menu": return ok(try menu(rest.first))
            case "keys", "keysel", "keymove", "keyease", "keydel": return ok(try keyCommand(command, rest))
            case "quit":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
                return ok("quitting")
            default: throw DebugError("unknown command '\(command)'\n\n\(Self.help)")
            }
        } catch {
            return LiveResponse(open: false, error: (error as? DebugError)?.message ?? "\(error)")
        }
    }

    // MARK: Finding things

    private struct DebugError: Error { var message: String; init(_ m: String) { message = m } }

    private func ok(_ text: String) -> LiveResponse { LiveResponse(open: true, text: text) }

    private func arg(_ a: [String], _ i: Int, _ name: String) throws -> String {
        guard i < a.count else { throw DebugError("missing \(name)") }
        return a[i]
    }

    private func hooks() throws -> DebugHooks {
        guard let front else { throw DebugError("no document window") }
        return front
    }

    private func findCanvas(in view: NSView) -> CanvasNSView? {
        if let c = view as? CanvasNSView { return c }
        for sub in view.subviews { if let c = findCanvas(in: sub) { return c } }
        return nil
    }

    /// The document window in front (by window order, so it works while the app is in the background).
    private func window() throws -> NSWindow {
        guard let w = NSApp.orderedWindows.first(where: { $0.isVisible && $0.contentView.map(findCanvas) != nil }) else {
            throw DebugError("no document window")
        }
        return w
    }

    private func canvas() throws -> CanvasNSView {
        guard let c = try window().contentView.flatMap(findCanvas) else { throw DebugError("no canvas") }
        return c
    }

    // MARK: Commands

    private func state() throws -> String {
        let h = try hooks(), doc = h.document.model, w = try window()
        var lines = [
            "window \(Int(w.frame.width))x\(Int(w.frame.height)) \"\(w.title)\"",
            "page \"\(doc.name)\" (\(h.document.file.pages.count) pages), \(doc.elements.count) elements, \(h.selection().count) selected",
        ]
        if let tl = doc.timeline {
            lines.append("timeline \(tl.duration)s at \(tl.fps) fps, \(tl.tracks.count) tracks, boil \(tl.boil.map(String.init) ?? "off"), settle \(tl.settle == true)")
        } else {
            lines.append("no timeline")
        }
        let p = h.playhead().map { String(format: "%.2fs", $0) } ?? "none"
        lines.append("playhead \(p), \(h.playing() ? "playing" : "paused")\(h.playhead() != nil && !h.playing() ? " (posing)" : "")")
        return lines.joined(separator: "\n")
    }

    private func snapshot(_ view: NSView, to url: URL) throws -> String {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DebugError("could not make a bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw DebugError("could not encode PNG") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        return "wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))"
    }

    private func select(_ query: String) throws -> String {
        let h = try hooks(), doc = h.document.model
        let ids: Set<UUID>
        switch query {
        case "all": ids = Set(doc.elements.map(\.id))
        case "none", "": ids = []
        default: ids = Set(doc.elements.filter { ($0.text ?? "").localizedCaseInsensitiveContains(query) }.map(\.id))
        }
        h.setSelection(ids)
        return "selected \(ids.count)"
    }

    private func action(_ a: [String]) throws -> String {
        let h = try hooks(), e = h.editor()
        let name = try arg(a, 0, "action name")
        switch name {
        case "newAnimation": e.newAnimation()
        case "removeAnimation": e.removeAnimation()
        case "transition":
            guard let t = DottieKit.Transition(rawValue: try arg(a, 1, "transition")) else {
                throw DebugError("transitions: \(DottieKit.Transition.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            e.addTransition(t)
        case "packet": e.sendPacket()
        case "build":
            let styles: [String: BuildStyle] = ["popIn": .popIn, "drawIn": .drawIn, "packets": .packets]
            guard let s = styles[try arg(a, 1, "style")] else { throw DebugError("build styles: popIn, drawIn, packets") }
            e.buildDiagram(s)
        case "boil": e.toggleBoil()
        case "settle": e.toggleSettle()
        case "clearKeys": e.clearKeys()
        case "undo": h.undoManager?.undo()
        case "redo": h.undoManager?.redo()
        default: throw DebugError("unknown action '\(name)'")
        }
        return "did \(a.joined(separator: " "))"
    }

    /// The first element whose text contains `text` (or, failing that, whose kind is `text`).
    private func element(_ text: String) throws -> Element {
        let doc = try hooks().document.model
        guard let e = doc.elements.first(where: { ($0.text ?? "").localizedCaseInsensitiveContains(text) })
                ?? doc.elements.first(where: { $0.kind.rawValue == text }) else { throw DebugError("no element matching '\(text)'") }
        return e
    }

    private func keyCommand(_ command: String, _ a: [String]) throws -> String {
        let h = try hooks(), e = try element(try arg(a, 0, "element text"))
        func time(_ i: Int) throws -> Double {
            guard let t = Double(try arg(a, i, "time")) else { throw DebugError("not a time: \(a[i])") }
            return t
        }
        switch command {
        case "keys":
            let keys = h.document.model.timeline?.track(for: e.id)?.keys ?? []
            return keys.map { k in
                let sets = TimelineRows.mark(k).sets.map(\.rawValue).sorted().joined(separator: ",")
                return "\(k.t)s \(sets) \(k.ease?.rawValue ?? "linear")"
            }.joined(separator: "\n").ifEmpty("no keys")
        case "keysel":
            h.setSelectedKey(a.count > 1 && a[1] != "none" ? KeyRef(element: e.id, t: try time(1)) : nil)
            return "selected key"
        case "keymove":
            let from = try time(1), to = try time(2), copy = a.count > 3 && a[3] == "copy"
            h.editTimeline(copy ? "Copy Key" : "Move Key") { $0.moveKey(of: e.id, from: from, to: to, copy: copy) }
            return "moved key"
        case "keyease":
            guard let ease = Ease(rawValue: try arg(a, 2, "ease")) else { throw DebugError("eases: \(Ease.allCases.map(\.rawValue))") }
            let t = try time(1)
            h.editTimeline("Set Ease") { $0.setEase(ease, of: e.id, at: t) }
            return "set ease"
        default:
            let t = try time(1)
            h.editTimeline("Delete Key") { $0.removeKey(of: e.id, at: t) }
            return "deleted key"
        }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in view: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ a: CGPoint, _ b: CGPoint, steps: Int = 12) throws {
        let c = try canvas(), w = try window()
        c.mouseDown(with: mouse(.leftMouseDown, a, in: c, window: w))
        for i in stride(from: 1, through: steps, by: 1) {
            let t = CGFloat(i) / CGFloat(steps)
            c.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), in: c, window: w))
        }
        c.mouseUp(with: mouse(.leftMouseUp, b, in: c, window: w))
    }

    private func key(_ k: String) throws -> String {
        let c = try canvas(), w = try window()
        let (chars, code): (String, UInt16) = switch k {
        case "esc": ("\u{1b}", 53)
        case "delete": ("\u{7f}", 51)
        default: (k, 0)
        }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        c.keyDown(with: event)
        return "pressed \(k)"
    }

    private func menu(_ path: String?) throws -> String {
        guard var menu = NSApp.mainMenu else { throw DebugError("no menu bar") }
        for title in (path ?? "").split(separator: "/").map(String.init) {
            guard let item = menu.items.first(where: { $0.title == title }), let sub = item.submenu else {
                throw DebugError("no menu '\(title)' in \(menu.items.map(\.title).filter { !$0.isEmpty })")
            }
            menu = sub
        }
        menu.update()
        func dump(_ m: NSMenu, _ depth: Int) -> [String] {
            m.items.flatMap { item -> [String] in
                let pad = String(repeating: "  ", count: depth)
                if item.isSeparatorItem { return ["\(pad)---"] }
                if item.isSectionHeader { return ["\(pad)[\(item.title)]"] }
                let mark = item.state == .on ? "✓ " : ""
                let line = "\(pad)\(mark)\(item.title)\(item.isEnabled ? "" : "  (disabled)")\(item.keyEquivalent.isEmpty ? "" : "  ⌘\(item.keyEquivalent)")"
                // Only open submenus of the menu asked for, so the whole menu bar stays readable.
                guard let sub = item.submenu, path != nil else { return [line] }
                sub.update()
                return [line] + dump(sub, depth + 1)
            }
        }
        return dump(menu, 0).joined(separator: "\n")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif
