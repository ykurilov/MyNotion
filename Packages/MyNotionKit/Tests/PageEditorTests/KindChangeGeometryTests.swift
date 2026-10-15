import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Блок, ставший пунктом списка, выглядит как соседний пункт: маркер и текст или подсказка «Список» на тех же местах
/// (баг Юрия 15.10.2026: последний блок страницы рисовался без отступа, подсказка пустого пункта — на ≈ 3 правее текста).
@MainActor
@Suite("Смена типа блока: геометрия")
struct KindChangeGeometryTests {
    enum Path: CaseIterable { case shortcut, slashMenu, blockMenu }

    /// Где рисунок блока: в колонке маркера и в строке текста (координаты окна текста).
    private func ink(ofBlock index: Int, in editor: EditorFixture, appearance: NSAppearance.Name) throws -> (marker: NSRect?, text: NSRect?) {
        let textView = editor.textView
        let line = try #require(textView.markerLine(ofBlockAt: index))
        let origin = textView.textContainerOrigin
        let column = line.markerColumn.offsetBy(dx: origin.x, dy: origin.y)
        let text = NSRect(x: column.maxX, y: column.minY, width: 300, height: column.height)
        let pixels = try ViewPixels(textView, appearance: appearance)
        let page = Palette.pageBackground.resolved(in: appearance)
        return (pixels.inkBounds(in: column, over: page), pixels.inkBounds(in: text, over: page))
    }

    private func changeToBullet(block index: Int, by path: Path, in editor: EditorFixture) {
        editor.placeCaret(inBlock: index)
        switch path {
        case .shortcut:
            editor.type("- ")
        case .slashMenu:
            editor.type("/марк")
            editor.press(#selector(NSResponder.insertNewline(_:)))
        case .blockMenu:
            editor.step {
                editor.textView.openBlockMenu(forBlock: editor.document.blocks[index].id, below: .zero)
                editor.textView.popups.choose(PopupMenuItem.blockKinds.first { $0.action == .setKind(.bulletItem) })
            }
            editor.placeCaret(inBlock: index)
        }
    }

    @Test("Пункт списка, сделанный из абзаца, — маркер и текст (или подсказка) там же, где у соседнего пункта",
          arguments: Path.allCases, [true, false])
    func changedBlockMatchesNeighbour(path: Path, isLastBlock: Bool) throws {
        for text in ["", "Список"] {
            var specs: [EditorFixture.Spec] = [.bullet("Список"), .bullet(""), .paragraph("Абзац после пустого блока."), .paragraph(text)]
            if !isLastBlock { specs.append(.paragraph("Ниже")) }
            let editor = try EditorFixture(specs)
            changeToBullet(block: 3, by: path, in: editor)
            #expect(editor.kinds[3] == .bulletItem && editor.texts[3] == text, "\(path): тип \(editor.kinds[3]), текст «\(editor.texts[3])»")

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let reference = try ink(ofBlock: 0, in: editor, appearance: appearance)
                let changed = try ink(ofBlock: 3, in: editor, appearance: appearance)
                let where_ = "\(path), \(isLastBlock ? "последний" : "в середине"), «\(text)», \(appearance.rawValue)"
                let marker = try #require(changed.marker, "\(where_): маркера нет")
                let referenceMarker = try #require(reference.marker)
                #expect(abs(marker.minX - referenceMarker.minX) <= 0.5 && abs(marker.width - referenceMarker.width) <= 0.5,
                        "\(where_): маркер \(marker), у соседа \(referenceMarker)")
                let changedText = try #require(changed.text, "\(where_): ни текста, ни подсказки")
                let referenceText = try #require(reference.text)
                #expect(abs(changedText.minX - referenceText.minX) <= 0.5,
                        "\(where_): \(text.isEmpty ? "подсказка" : "текст") с \(changedText.minX), текст соседа с \(referenceText.minX)")
            }
        }
    }

    @Test("Подсказка пустого пункта без курсора начинается там же, где текст соседнего пункта")
    func placeholderStartsAtText() throws {
        let editor = try EditorFixture([.bullet("Список"), .bullet(""), .paragraph("Абзац")])
        editor.placeCaret(inBlock: 2)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let reference = try #require(try ink(ofBlock: 0, in: editor, appearance: appearance).text)
            let hint = try #require(try ink(ofBlock: 1, in: editor, appearance: appearance).text, "подсказки нет")
            #expect(abs(hint.minX - reference.minX) <= 0.5, "\(appearance.rawValue): подсказка с \(hint.minX), текст с \(reference.minX)")
        }
    }
}
