import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Меню блока «⋮⋮», как у Notion 7.39: короткое, типы и цвет — подменю справа; фокус между окнами — стрелками.
@MainActor
@Suite("Меню блока")
struct BlockMenuTests {
    private func openMenu(_ editor: EditorFixture, block index: Int) {
        editor.textView.openBlockMenu(forBlock: editor.document.blocks[index].id, below: NSRect(x: 100, y: 500, width: 20, height: 20))
    }

    @Test("Короткое меню: заголовок — тип блока; «Преобразовать в», «Цвет», «Дублировать» ⌘D, «Переместить в» ⇧⌘P, «Удалить» Del")
    func shortMenu() throws {
        let editor = try EditorFixture([.paragraph("один"), .heading(2, "два")])
        openMenu(editor, block: 1)
        let popups = editor.textView.popups
        #expect(popups.sectionTitle == "Заголовок 2")
        #expect(popups.visibleItems.map(\.title) == ["Преобразовать в", "Цвет", "Дублировать", "Переместить в", "Удалить"])
        #expect(popups.visibleItems.map(\.hint) == [nil, nil, "⌘D", "⇧⌘P", "Del"])
        #expect(popups.visibleItems.map(\.startsGroup) == [false, false, true, false, false])
        #expect(popups.visibleItems.map(\.opensSubmenu) == [true, true, false, false, false])
        let frame = try #require(popups.menuFrame)
        #expect(frame.width == Metrics.PopupMenu.blockMenuWidth)
    }

    @Test("→ открывает «Преобразовать в» справа: текущий тип отмечен и выбран; ↓ и Enter меняют тип, меню закрываются")
    func turnIntoByKeyboard() throws {
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два")])
        openMenu(editor, block: 1)
        let popups = editor.textView.popups
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(popups.submenu == .turnInto)
        #expect(popups.isSubmenuFocused)
        #expect(popups.submenuItems == PopupMenuItem.blockKinds)
        #expect(popups.submenuCheckedItem?.action == .setKind(.paragraph))
        #expect(popups.submenuSelectedItem?.action == .setKind(.paragraph))
        let menu = try #require(popups.menuFrame), submenu = try #require(popups.submenuFrame)
        #expect(submenu.minX == menu.maxX - Metrics.PopupMenu.submenuOverlap)
        #expect(submenu.width == Metrics.PopupMenu.kindListWidth)

        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(popups.submenuSelectedItem?.action == .setKind(.heading1))
        #expect(popups.selectedItem?.action == .turnInto, "Строка меню остаётся подсвеченной")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(!popups.isOpen)
        #expect(popups.submenu == nil)
        #expect(editor.document.blocks[1].kind == .heading1)
        editor.undo()
        #expect(editor.document.blocks[1].kind == .paragraph)
    }

    @Test("← и Esc в подменю возвращают в меню; Esc в меню закрывает всё")
    func leaveSubmenu() throws {
        let editor = try EditorFixture([.paragraph("один")])
        openMenu(editor, block: 0)
        let popups = editor.textView.popups
        editor.press(#selector(NSResponder.moveRight(_:)))
        editor.press(#selector(NSResponder.moveLeft(_:)))
        #expect(popups.isOpen && popups.submenu == nil && !popups.isSubmenuFocused)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(popups.submenu == .turnInto && popups.isSubmenuFocused, "Enter на строке с подменю — тоже вход в него")
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(popups.isOpen && popups.submenu == nil)
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!popups.isOpen)
    }

    @Test("↓ со строки с подменю закрывает подменю; стрелки ходят по меню")
    func movingOffClosesSubmenu() throws {
        let editor = try EditorFixture([.paragraph("один")])
        openMenu(editor, block: 0)
        let popups = editor.textView.popups
        popups.openSubmenu(for: .turnInto, focus: false)
        #expect(popups.submenu == .turnInto && !popups.isSubmenuFocused, "Наведение мыши открывает подменю без фокуса")
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(popups.submenu == nil)
        #expect(popups.selectedItem?.action == .color)
    }

    @Test("«Цвет» — окно цветов справа от меню, вровень со строкой; Esc — назад в меню; выбор красит блок и закрывает всё")
    func colorSubmenu() throws {
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два")])
        editor.textView.recentColors = RecentColors(defaults: nil)
        openMenu(editor, block: 1)
        let popups = editor.textView.popups
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(popups.submenu == .color && popups.isSubmenuFocused)
        #expect(editor.textView.colorMenu.target == .block(editor.document.blocks[1].id))
        let menu = try #require(popups.menuFrame), colors = try #require(editor.textView.colorMenu.menuFrame)
        #expect(colors.minX == menu.maxX - Metrics.PopupMenu.submenuOverlap)
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(popups.isOpen && !editor.textView.colorMenu.isOpen)

        editor.press(#selector(NSResponder.moveRight(_:)))
        editor.press(#selector(NSResponder.moveLeft(_:)))
        #expect(!editor.textView.colorMenu.isOpen, "← у левого края окна цветов — назад в меню")
        editor.press(#selector(NSResponder.moveRight(_:)))
        editor.step { editor.textView.colorMenu.choose(ColorChoice(target: .background, color: .blue)) }
        #expect(!popups.isOpen && !editor.textView.colorMenu.isOpen)
        #expect(editor.document.blocks[1].color.background == .blue)
    }

    @Test("Дублировать: копия со вложенными блоками и таблицей — сразу под оригиналом, новые id, ⌘Z убирает")
    func duplicateWithChildrenAndTable() throws {
        let editor = try EditorFixture([.paragraph("до"), Spec(kind: .toggle, text: "Раздел"), Spec(kind: .paragraph, text: "внутри", indent: 1),
                                        .paragraph("после")])
        let tableIndex = 3
        editor.step { editor.textView.insertTable(at: tableIndex) }
        let table = try #require(editor.document.blocks.first { $0.kind == .table })
        let grid = try #require(editor.document.tableGrid(table.id))
        _ = editor.document.apply(grid.settingText(InlineText("ячейка"), row: 0, column: 1))
        let before = editor.document.blocks.map(\.kind)

        openMenu(editor, block: 1)
        editor.step { editor.textView.popups.choose(.duplicate) }
        #expect(editor.document.blocks.map { "\($0.indent) \($0.kind.rawValue) \($0.text.string)" }.prefix(5) == [
            "0 paragraph до", "0 toggle Раздел", "1 paragraph внутри", "0 toggle Раздел", "1 paragraph внутри",
        ])
        let ids = editor.document.blocks.map(\.id)
        #expect(Set(ids).count == ids.count)

        let tableAt = try #require(editor.document.blocks.firstIndex { $0.kind == .table })
        editor.placeCaret(inBlock: 0)
        editor.step { editor.textView.duplicateBlocks(at: tableAt..<tableAt + 1) }
        let tables = editor.document.blocks.filter { $0.kind == .table }
        #expect(tables.count == 2)
        let copy = try #require(editor.document.tableGrid(tables[1].id))
        #expect(copy.text(row: 0, column: 1).string == "ячейка", "Ячейка копии — в копии своего столбца")
        #expect(copy.table.id != table.id)

        editor.undo()
        editor.undo()
        #expect(editor.document.blocks.map(\.kind) == before)
    }

    @Test("⌘D дублирует блок под курсором")
    func commandD() throws {
        #expect(EditorKeyBindings.command(characters: "d", modifiers: .command) == .duplicateBlocks)
        let editor = try EditorFixture([.paragraph("один"), .paragraph("два")])
        editor.placeCaret(inBlock: 0, at: 2)
        editor.perform(.duplicateBlocks)
        #expect(editor.texts == ["один", "один", "два"])
    }

    @Test("Подстраницу не дублировать: в её меню нет «Дублировать», группу начинает «Переместить в»")
    func pageLinkHasNoDuplicate() {
        #expect(!PopupMenuItem.blockMenuItems(for: .pageLink).contains(.duplicate))
        #expect(PopupMenuItem.blockMenuItems(for: .pageLink).first { $0.action == .moveTo }?.startsGroup == true)
    }

    @Test("Длинный список по высоте экрана: строки целиком, прокрутка за выбранной строкой, полоса прокрутки")
    func longListScrolls() {
        let view = PopupMenuView(style: .kindPicker)
        view.setItems(PopupMenuItem.blockKinds)
        let full = view.fittingMenuSize.height
        view.maximumHeight = 200
        let capped = view.fittingMenuSize.height
        #expect(capped <= 200 && capped < full)
        #expect(view.isScrollable)
        let rowsHeight = capped - 2 * Metrics.PopupMenu.verticalPadding
        #expect(rowsHeight.truncatingRemainder(dividingBy: Metrics.PopupMenu.compactRowHeight) == 0, "Нижняя строка не срезана")
        let last = PopupMenuItem.blockKinds.last!
        view.select(last)
        #expect(view.scrollOffset > 0)
        #expect(view.selectedItem == last)
        view.maximumHeight = .greatestFiniteMagnitude
        #expect(!view.isScrollable)
        #expect(view.scrollOffset == 0)
    }
}

private typealias Spec = EditorFixture.Spec
