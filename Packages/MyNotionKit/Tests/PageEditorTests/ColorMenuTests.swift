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

    @Test("Кнопка «A» — первая на панели, как у Notion 7.39; без цветов в истории «Последних» в окне нет")
    func barOpensMenuWithoutRecent() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        #expect(FormatBarButton.allCases.first == .color)
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

    @Test("Выбор в окне красит выделение, окно остаётся открытым с кольцом у нового цвета (Notion 7.39); «Последние» — при следующем открытии")
    func choosingColorsSelection() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        editor.step { editor.textView.colorMenu.choose(choice(.text, .red)) }
        #expect(editor.textView.colorMenu.isOpen)
        #expect(editor.textView.colorMenu.currentChoices == [choice(.text, .red), choice(.background, nil)])
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 5, length: 3, style: .textColor(.red))])
        #expect(editor.textView.selectedRange() == NSRange(location: 5, length: 3), "Выделение остаётся")
        #expect(editor.textView.formatBar.state?.currentColors == [choice(.text, .red), choice(.background, nil)],
                "Кнопка «A» — текущим цветом выделения")

        editor.textView.formatBar.press(.color)
        #expect(!editor.textView.colorMenu.isOpen)
        editor.textView.formatBar.press(.color)
        #expect(editor.textView.colorMenu.rows.prefix(2) == [.header("Последние"), .choice(choice(.text, .red), .recent)])
    }

    @Test("Стрелки ходят по сетке 5 в ряд, Enter красит, Esc закрывает; ввод остаётся в тексте")
    func keyboard() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        editor.press(#selector(NSResponder.moveRight(_:)))
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(editor.textView.colorMenu.selectedChoice == choice(.text, .brown))
        editor.press(#selector(NSResponder.moveLeft(_:)))
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(editor.textView.colorMenu.selectedChoice == choice(.text, .blue), "↓ — тот же столбец рядом ниже")
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(editor.textView.colorMenu.selectedChoice == choice(.background, .gray), "↓ из последнего ряда раздела — в следующий раздел")
        editor.press(#selector(NSResponder.moveUp(_:)))
        editor.press(#selector(NSResponder.moveUp(_:)))
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.document.blocks[0].text.runs == [StyledRun(start: 5, length: 3, style: .textColor(.gray))])

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

    @Test("Текущий цвет выделения помечен в окне: у слова без цвета — «По умолчанию», у окрашенного — его цвет")
    func currentColorOfSelection() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        #expect(editor.textView.colorMenu.currentChoices == [choice(.text, nil), choice(.background, nil)])
        editor.step { editor.textView.colorMenu.choose(choice(.text, .red)) }
        editor.step { editor.textView.colorMenu.close() }

        editor.textView.formatBar.press(.color)
        editor.step { editor.textView.colorMenu.choose(choice(.background, .yellow)) }
        #expect(editor.textView.colorMenu.currentChoices == [choice(.text, .red), choice(.background, .yellow)], "Кольцо — сразу у нового цвета")
        editor.step { editor.textView.colorMenu.close() }
        editor.textView.formatBar.press(.color)
        #expect(editor.textView.colorMenu.currentChoices == [choice(.text, .red), choice(.background, .yellow)])
    }

    @Test("Выделение с разными цветами — в этом виде цвета отметки нет; цвет другого вида отмечен по-прежнему")
    func mixedSelectionHasNoMark() throws {
        let editor = try editor([.paragraph("один два")])
        editor.select(inBlock: 0, "два")
        editor.textView.formatBar.press(.color)
        editor.step { editor.textView.colorMenu.choose(choice(.text, .red)) }
        editor.select(inBlock: 0, "один два")
        #expect(!editor.textView.colorMenu.isOpen, "Новое выделение закрывает окно цветов")
        editor.textView.formatBar.press(.color)
        #expect(editor.textView.colorMenu.currentChoices == [choice(.background, nil)])
    }

    @Test("Цвет блока отмечен в окне, открытом из меню блока")
    func currentColorOfBlock() throws {
        let editor = try editor([.paragraph("один"), .paragraph("два")])
        let id = editor.document.blocks[1].id
        editor.textView.openBlockMenu(forBlock: id, below: .zero)
        editor.step { editor.textView.popups.choose(.color) }
        #expect(editor.textView.colorMenu.currentChoices == [choice(.text, nil), choice(.background, nil)])
        editor.step { editor.textView.colorMenu.choose(choice(.background, .blue)) }

        editor.textView.openBlockMenu(forBlock: id, below: .zero)
        editor.step { editor.textView.popups.choose(.color) }
        #expect(editor.textView.colorMenu.currentChoices == [choice(.text, nil), choice(.background, .blue)])
    }

    @Test("Окно цветов, как у Notion 7.39: под местом кнопки «A», левым краем с ним вровень, поверх панели; внизу нет места — над ним")
    func placementUnderColorButton() {
        let visible = NSRect(x: 100, y: 100, width: 800, height: 700)
        let size = NSSize(width: Metrics.ColorMenu.width, height: 280)
        let button = NSRect(x: 307, y: 600, width: Metrics.FormatBar.buttonWidth, height: Metrics.FormatBar.buttonRowHeight)
        let below = FormatBarPlacement.colorMenu(size: size, button: button, visible: visible)
        #expect(below.minX == button.minX)
        #expect(below.maxY == button.minY - Metrics.FormatBar.colorMenuGap)

        let low = NSRect(x: 307, y: 250, width: Metrics.FormatBar.buttonWidth, height: Metrics.FormatBar.buttonRowHeight)
        let above = FormatBarPlacement.colorMenu(size: size, button: low, visible: visible)
        #expect(above.minY == low.maxY + Metrics.FormatBar.colorMenuGap)

        let edge = NSRect(x: 880, y: 600, width: Metrics.FormatBar.buttonWidth, height: Metrics.FormatBar.buttonRowHeight)
        #expect(FormatBarPlacement.colorMenu(size: size, button: edge, visible: visible).maxX == visible.maxX)
    }

    @Test("Сетка, как у Notion 7.39: 5 образцов 26 в ряд с просветом 8, поля 16; заголовок раздела 32 над рядами")
    func gridGeometry() {
        let withoutRecent = ColorMenuRow.rows(recent: [])
        let layout = ColorMenuLayout(rows: withoutRecent)
        #expect(Metrics.ColorMenu.width == 194)
        #expect(layout.swatchFrames.count == 20)
        #expect(layout.swatchFrames[0] == NSRect(x: 16, y: 36, width: 26, height: 26))
        #expect(layout.swatchFrames[4].minX == CGFloat(16 + 4 * 34))
        #expect(layout.swatchFrames[5].minY == CGFloat(36 + 34), "Второй ряд раздела")
        #expect(layout.swatchFrames[10].minY == layout.swatchFrames[5].maxY + 9 + 32, "Раздел фона — под заголовком")
        #expect(layout.height == layout.swatchFrames[19].maxY + 14)

        let recent = [choice(.text, .red), choice(.background, .blue)]
        let withRecent = ColorMenuLayout(rows: ColorMenuRow.rows(recent: recent))
        #expect(withRecent.swatchFrames.count == 22)
        #expect(withRecent.height == 278, "Как у Notion: с одним рядом «Последних» ≈ 278")
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
