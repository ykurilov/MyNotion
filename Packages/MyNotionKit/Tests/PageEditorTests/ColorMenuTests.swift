import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Окно цветов: кнопка «A» на панели форматирования и пункт «Цвет» в меню блока (FR-112).
@MainActor
@Suite("Окно цветов")
struct ColorMenuTests {
    private func editor(_ specs: [EditorFixture.Spec]) throws -> EditorFixture {
        let editor = try EditorFixture(specs)
        editor.textView.recentColors = RecentColors(defaults: nil)
        return editor
    }

    private func choice(_ target: ColorTarget, _ color: NotionColor?) -> ColorChoice { ColorChoice(target: target, color: color) }

    @Test("Кнопка «A» — последняя на панели; без цветов в истории «Последних» в окне нет")
    func barOpensMenuWithoutRecent() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        #expect(FormatBarButton.allCases.last == .color)
        editor.textView.formatBar.press(.color)
        let menu = editor.textView.colorMenu
        #expect(menu.isOpen)
        #expect(menu.target == .selection)
        let rows = menu.rows
        #expect(!rows.contains(.header("Последние")))
        #expect(rows.first == .header("Цвет текста"))
        let choices = rows.compactMap(\.choice)
        #expect(choices.count == 20)
        #expect(choices.prefix(10).allSatisfy { $0.target == .text } && choices.suffix(10).allSatisfy { $0.target == .background })
        #expect(choices[0].color == nil && choices[10].color == nil, "«По умолчанию» первым в каждом разделе")
        #expect(editor.textView.formatBar.isShown, "Панель остаётся, пока открыто окно")
    }

    @Test("Повторное нажатие «A» закрывает окно; список типов и окно цветов вместе не открыты")
    func toggleAndExclusive() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        let bar = editor.textView.formatBar
        bar.press(.color)
        bar.press(.color)
        #expect(!editor.textView.colorMenu.isOpen)

        bar.press(.color)
        bar.openKindMenu()
        #expect(!editor.textView.colorMenu.isOpen)
        #expect(bar.isKindMenuOpen)
        bar.press(.color)
        #expect(editor.textView.colorMenu.isOpen)
        #expect(!bar.isKindMenuOpen)
    }

    @Test("Выбор в окне красит выделение и закрывает окно; «Последние» запоминают выбор")
    func choosingColorsSelection() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        editor.step { editor.textView.colorMenu.choose(choice(.text, .red)) }
        #expect(!editor.textView.colorMenu.isOpen)
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 5, length: 3, style: .textColor(.red))])
        #expect(editor.textView.formatBar.state?.lastColor == choice(.text, .red), "Кнопка «A» подчёркнута последним цветом")

        editor.textView.formatBar.press(.color)
        #expect(editor.textView.colorMenu.rows.prefix(2) == [.header("Последние"), .choice(choice(.text, .red), .recent)])
    }

    @Test("Стрелки, Enter и Esc управляют окном, ввод остаётся в тексте")
    func keyboard() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(editor.textView.colorMenu.selectedChoice == choice(.text, .brown))
        editor.press(#selector(NSResponder.moveUp(_:)))
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 5, length: 3, style: .textColor(.gray))])

        editor.textView.formatBar.press(.color)
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!editor.textView.colorMenu.isOpen)
        #expect(editor.document.blocks.count == 1)
    }

    @Test("Выделение ушло — окно цветов закрылось вместе с панелью")
    func closesWithBar() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        editor.placeCaret(inBlock: 0, at: 1)
        #expect(!editor.textView.formatBar.isShown)
        #expect(!editor.textView.colorMenu.isOpen)
    }

    @Test("Меню блока: пункт «Цвет» перед «Удалить»; выбор открывает окно цветов для блока и красит его целиком")
    func blockMenuColor() throws {
        let editor = try editor([.paragraph("один"), .heading(2, "два")])
        let id = editor.document.blocks[1].id
        editor.textView.openBlockMenu(forBlock: id, below: .zero)
        let items = editor.textView.popups.visibleItems
        #expect(items.suffix(2).map(\.title) == ["Цвет", "Удалить"])

        editor.step { editor.textView.popups.choose(.color) }
        #expect(!editor.textView.popups.isOpen, "Меню блока заменено окном цветов")
        #expect(editor.textView.colorMenu.target == .block(id))

        editor.step { editor.textView.colorMenu.choose(choice(.background, .blue)) }
        #expect(!editor.textView.colorMenu.isOpen)
        #expect(editor.document.blocks.map(\.color) == [.none, BlockColor(background: .blue)])
        #expect(editor.textView.isBlockSelection, "Блок остаётся выделенным")
    }
}
