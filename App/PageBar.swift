import SwiftUI
import DottieKit

/// The page tabs under the canvas. Click to show a page, double-click to rename, drag to reorder;
/// the context menu renames, duplicates, adds, moves and deletes.
struct PageBar: View {
    @ObservedObject var document: DrawingDocument
    var undoManager: UndoManager?
    @State private var renaming: UUID?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private static let dragPrefix = "dottie-page:"

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(document.file.pages) { page in tab(page).id(page.id) }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: document.currentPageID) { _, id in withAnimation { scroller.scrollTo(id) } }
            }
            BarDivider()
            IconButton("plus", help: "New Page (⌥⌘N)") { document.addPage(undoManager: undoManager) }
                .padding(.horizontal, 10)
        }
        .frame(height: 30)
        .background(.bar)
        .onChange(of: document.renamingPage) { _, id in
            guard let id, let page = document.file.page(id) else { return }
            document.renamingPage = nil
            beginRename(page)
        }
    }

    @ViewBuilder
    private func tab(_ page: DottieDocument) -> some View {
        let current = page.id == document.currentPageID
        Group {
            if renaming == page.id {
                TextField("Page", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .frame(width: max(60, CGFloat(draft.count) * 7.5))
                    .onSubmit { finishRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: fieldFocused) { _, now in if !now { finishRename() } }
            } else {
                Text(page.name).lineLimit(1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(current ? .primary : .secondary)
        .background(current ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(page) }
        .simultaneousGesture(TapGesture().onEnded { document.currentPageID = page.id })
        .draggable(Self.dragPrefix + page.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, s.hasPrefix(Self.dragPrefix),
                  let dragged = UUID(uuidString: String(s.dropFirst(Self.dragPrefix.count))), dragged != page.id,
                  let to = document.file.index(of: page.id) else { return false }
            document.movePage(dragged, to: to, undoManager: undoManager)
            return true
        }
        .contextMenu {
            Button("Rename…") { beginRename(page) }
            Button("Duplicate") { document.duplicatePage(page.id, undoManager: undoManager) }
            Button("New Page After") { document.currentPageID = page.id; document.addPage(undoManager: undoManager) }
            Divider()
            let i = document.file.index(of: page.id) ?? 0
            Button("Move Left") { document.movePage(page.id, to: i - 1, undoManager: undoManager) }.disabled(i == 0)
            Button("Move Right") { document.movePage(page.id, to: i + 1, undoManager: undoManager) }
                .disabled(i == document.file.pages.count - 1)
            Divider()
            Button("Delete Page") { document.deletePage(page.id, undoManager: undoManager) }
                .disabled(document.file.pages.count < 2)
        }
        .help(page.name)
    }

    private func beginRename(_ page: DottieDocument) {
        document.currentPageID = page.id
        draft = page.name
        renaming = page.id
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func finishRename() {
        guard let id = renaming else { return }
        renaming = nil
        document.renamePage(id, to: draft, undoManager: undoManager)
    }
}
