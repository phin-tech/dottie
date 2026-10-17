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
    state                        what the front window shows (page, tool, selection, timeline)
    open <file.dottie>           open a document (give it a moment, then `state`)
    size <width> <height>        resize the front window's content
    snapshot <out.png> [canvas|popover]   render the window (or just the canvas, or an open popover) to a PNG
    playhead <seconds|none>      move the playhead (paused there, the canvas poses that frame)
    play | pause | done          play, pause, or stop previewing
    select all|none|<text>       select shapes whose text contains <text>
    action <name> [arg]          newAnimation, removeAnimation, transition <popIn|...>, packet,
                                 build <popIn|drawIn|packets>, boil, settle, clearKeys, scene [t], timing, camera
                                 (frame the selection), removeCamera, repeat, makeSymbol, editSymbol,
                                 doneSymbol, breakApart, undo, redo
    drag <x1> <y1> <x2> <y2>     drag on the canvas, in canvas points (top-left origin)
    click <x> <y>                click on the canvas
    move <x> <y>                 move the pointer over the canvas without pressing (the rulers mark where it is)
    rightclick <x> <y> [Item/Sub]   right-click the canvas and list its context menu, or choose an item in it
    key [mods+]<key>|release    send a key to the canvas (cmd+right, opt+down, tab, shift+1, esc); release lets go of modifiers
    keys <text>                  list the keys of the element whose text contains <text>
    keysel <text> <t>            select that element's key at <t> in the timeline (none: clear)
    keymove <text> <from> <to> [copy]   retime (or copy) a key, as dragging a diamond does
    keyease <text> <t> <ease>    set a key's ease: linear, easeIn, easeOut, easeInOut, hold, spring, bounce, elastic
    keydel <text> <t>            delete a key
    menu [Top/Sub/...]           list the menu bar (or a menu), or choose the item a path ends at; items read as disabled while the app is in
                                 the background, since commands follow the focused window
    onion on|off                 onion skinning while posing (the Animate menu's toggle)
    exportanim <format> <path>   write the page's animation as File > Export Animation does, without the
                                 save panel: gif, apng, mp4, player, lottieSmooth, lottieExact
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
                let view: NSView
                switch rest.count > 1 ? rest[1] : "" {
                case "canvas": view = try canvas()
                case "popover":
                    guard let w = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
                          let v = w.contentView else { throw DebugError("no popover open") }
                    view = v
                default: view = try window().contentView!.superview!
                }
                // Some controls don't draw into a cached bitmap; name them so a blank spot can be told from a missing one.
                func controls(_ v: NSView) -> [String] {
                    (v is NSControl ? [String(describing: type(of: v)) + ((v as? NSControl)?.isEnabled == false ? " (disabled)" : "")] : [])
                        + v.subviews.flatMap(controls)
                }
                let note = rest.count > 1 && rest[1] == "popover" ? "\ncontrols: " + controls(view).joined(separator: ", ") : ""
                return ok(try snapshot(view, to: url) + note)
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
            case "move":
                guard let x = Double(try arg(rest, 0, "x")), let y = Double(try arg(rest, 1, "y")) else { throw DebugError("move takes two numbers") }
                let c = try canvas()
                c.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: x, y: y), in: c, window: try window()))
                return ok("moved")
            case "rightclick":
                guard let x = Double(try arg(rest, 0, "x")), let y = Double(try arg(rest, 1, "y")) else { throw DebugError("rightclick takes two numbers") }
                let c = try canvas()
                guard var m = c.menu(for: mouse(.rightMouseDown, CGPoint(x: x, y: y), in: c, window: try window())) else { return ok("no menu") }
                guard rest.count > 2 else { return ok(Self.dump(m, open: true)) }
                // An item path: choose it, as clicking it would.
                let path = rest[2...].joined(separator: " ").split(separator: "/").map(String.init)
                for (i, title) in path.enumerated() {
                    guard let index = m.items.firstIndex(where: { $0.title == title }) else { throw DebugError("no item '\(title)'") }
                    if i == path.count - 1 { let item = m.items[index]; guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else { throw DebugError("'\(title)' did nothing") } } else if let sub = m.items[index].submenu { m = sub }
                }
                return ok("chose \(path.joined(separator: " > ")) (canvas \(c.model.elements.count) elements, \(c.selection.count) selected; page \(try hooks().document.model.elements.count))")
            case "key": return ok(try key(rest.joined(separator: " ")))
            case "menu": return ok(try menu(rest.first))
            case "keys", "keysel", "keymove", "keyease", "keydel": return ok(try keyCommand(command, rest))
            case "exportanim":
                let name = try arg(rest, 0, "format"), path = try arg(rest, 1, "path")
                guard let format = AnimationExportFormat.allCases.first(where: { "\($0)" == name }) else {
                    throw DebugError("formats: " + AnimationExportFormat.allCases.map { "\($0)" }.joined(separator: ", "))
                }
                try format.write(try hooks().document.model, to: URL(fileURLWithPath: path))
                return ok("wrote \(path)")
            case "onion":
                UserDefaults.standard.set(rest.first == "on", forKey: "onionSkin")
                return ok("onion skin \(rest.first == "on" ? "on" : "off")")
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

    /// The canvas SwiftUI last updated for each document, registered by `CanvasView.updateNSView`. Searching the
    /// window's views for one could find a canvas SwiftUI had replaced (after a resize, say), whose edits reach no
    /// document.
    private var canvases: [ObjectIdentifier: WeakCanvas] = [:]
    private struct WeakCanvas { weak var view: CanvasNSView? }

    func register(_ canvas: CanvasNSView, for document: DrawingDocument) {
        canvases[ObjectIdentifier(document)] = WeakCanvas(view: canvas)
    }

    /// The front document's canvas, in a window.
    private func canvas() throws -> CanvasNSView {
        guard let c = canvases[ObjectIdentifier(try hooks().document)]?.view, c.window != nil else { throw DebugError("no canvas") }
        return c
    }

    /// The front document's window.
    private func window() throws -> NSWindow {
        guard let w = try canvas().window else { throw DebugError("no document window") }
        return w
    }

    // MARK: Commands

    private func state() throws -> String {
        let h = try hooks(), doc = h.document.model, w = try window()
        var lines = [
            "window \(Int(w.frame.width))x\(Int(w.frame.height)) \"\(w.title)\"",
            "page \"\(doc.name)\" (\(h.document.file.pages.count) pages), \(doc.elements.count) elements, \(h.selection().count) selected",
        ]
        if let c = try? canvas() {
            lines.append("tool \(c.tool.rawValue)")
            // The canvas edits a copy of the page; when they differ outside a gesture, its edits aren't arriving.
            if h.playhead() == nil, c.model != doc { lines.append("canvas out of step with the page (\(c.model.elements.count) elements there)") }
        }
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
        case "scene": e.addScene(a.count > 1 ? Double(a[1]) : nil)
        case "timing": e.editTiming()
        case "camera": e.frameCamera()
        case "removeCamera": e.removeCamera()
        case "repeat": e.repeatSelection()
        case "makeSymbol": e.makeSymbol()
        case "editSymbol": e.editSymbol()
        case "doneSymbol": e.doneEditingSymbol()
        case "breakApart": e.breakApart()
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

    /// A key press, with modifiers as prefixes (`cmd+right`, `opt+down`, `shift+1`, `tab`), or `release` to let go
    /// of every modifier (what ends a ⌘-arrow flowchart row).
    private func key(_ k: String) throws -> String {
        let c = try canvas(), w = try window()
        var parts = k.split(separator: "+").map(String.init)
        let name = parts.popLast() ?? ""
        var flags: NSEvent.ModifierFlags = []
        for m in parts {
            switch m {
            case "cmd": flags.insert(.command)
            case "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            default: throw DebugError("unknown modifier '\(m)' (cmd, opt, shift, ctrl)")
            }
        }
        if name == "release" {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                         keyCode: 55)!
            c.flagsChanged(with: event)
            return "released modifiers"
        }
        let (chars, code): (String, UInt16) = switch name {
        case "esc": ("\u{1b}", 53)
        case "delete": ("\u{7f}", 51)
        case "tab": ("\t", 48)
        case "return": ("\r", 36)
        case "left": ("\u{F702}", 123)
        case "right": ("\u{F703}", 124)
        case "down": ("\u{F701}", 125)
        case "up": ("\u{F700}", 126)
        case "1": (flags.contains(.shift) ? "!" : "1", 18)
        default: (name, 0)
        }
        if (123...126).contains(code) { flags.formUnion([.function, .numericPad]) } // as real arrow keys carry
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        c.keyDown(with: event)
        c.keyUp(with: NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code)!)
        return "pressed \(k)"
    }

    private func menu(_ path: String?) throws -> String {
        guard var menu = NSApp.mainMenu else { throw DebugError("no menu bar") }
        for title in (path ?? "").split(separator: "/").map(String.init) {
            if let item = menu.items.first(where: { $0.title == title }), item.submenu == nil {   // an item: choose it
                menu.update()
                guard item.isEnabled, let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
                    throw DebugError("'\(title)' did nothing")
                }
                return "chose \(title)"
            }
            guard let item = menu.items.first(where: { $0.title == title }), let sub = item.submenu else {
                throw DebugError("no menu '\(title)' in \(menu.items.map(\.title).filter { !$0.isEmpty })")
            }
            menu = sub
        }
        // Only open submenus of the menu asked for, so the whole menu bar stays readable.
        return Self.dump(menu, open: path != nil)
    }

    /// A menu as indented lines; `open` lists its submenus too.
    private static func dump(_ menu: NSMenu, open: Bool) -> String {
        func lines(_ m: NSMenu, _ depth: Int) -> [String] {
            m.update()
            return m.items.flatMap { item -> [String] in
                let pad = String(repeating: "  ", count: depth)
                if item.isSeparatorItem { return ["\(pad)---"] }
                if item.isSectionHeader { return ["\(pad)[\(item.title)]"] }
                let mark = item.state == .on ? "✓ " : ""
                let line = "\(pad)\(mark)\(item.title)\(item.isEnabled ? "" : "  (disabled)")\(item.keyEquivalent.isEmpty ? "" : "  ⌘\(item.keyEquivalent)")"
                guard let sub = item.submenu, open else { return [line] }
                return [line] + lines(sub, depth + 1)
            }
        }
        return lines(menu, 0).joined(separator: "\n")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif
