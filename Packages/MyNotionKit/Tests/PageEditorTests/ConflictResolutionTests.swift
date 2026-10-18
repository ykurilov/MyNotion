import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// «Две версии» (FR-021): выбор одной версии или обеих двумя блоками — обычная правка, она ложится поверх версии
/// в базе и не становится новым конфликтом.
@MainActor
@Suite("Выбор версии в «Двух версиях»")
struct ConflictResolutionTests {
    /// Блок правили «на другом Mac» (прямо в базе), а здесь набрали своё: автосохранение записало конфликт.
    private func fixtureWithConflict() throws -> (EditorFixture, Conflict) {
        let fixture = try EditorFixture([.paragraph("начало"), .paragraph("второй")])
        let blockId = fixture.document.blocks[0].id
        try fixture.store.write { tx in
            var block = try #require(try tx.block(blockId))
            block.text = InlineText("версия с другого Mac")
            try tx.updateBlock(block)
        }
        fixture.document.setText(InlineText("версия здесь"), ofBlock: blockId)
        _ = try fixture.savedBlocks()
        let conflicts = try fixture.store.unresolvedConflicts(ofPage: fixture.pageId)
        fixture.document.replacePendingConflicts(conflicts)
        return (fixture, try #require(conflicts.first))
    }

    private func resolve(_ fixture: EditorFixture, _ conflict: Conflict, _ choice: ConflictChoice) throws {
        var resolved: [UUID] = []
        fixture.textView.onResolveConflict = { conflict in
            resolved.append(conflict.id)
            try? fixture.store.write { try $0.resolveConflict(conflict.id) }
            fixture.document.replacePendingConflicts((try? fixture.store.unresolvedConflicts(ofPage: fixture.pageId)) ?? [])
        }
        fixture.step { fixture.textView.resolveConflict(conflict, choice: choice) }
        #expect(resolved == [conflict.id])
    }

    @Test("Метка «Две версии» появляется у блока в конфликте")
    func labelAppears() throws {
        let (fixture, _) = try fixtureWithConflict()
        fixture.textView.layoutSubtreeIfNeeded()
        let labels = fixture.textView.subviews.compactMap { $0 as? ConflictLabelView }
        #expect(labels.count == 1)
        #expect(labels.first?.isHidden == false)
    }

    @Test("«Оставить эту» — своя версия ложится в базу поверх чужой, без нового конфликта")
    func keepCurrent() throws {
        let (fixture, conflict) = try fixtureWithConflict()
        try resolve(fixture, conflict, .current)
        #expect(try fixture.savedBlocks().map(\.text.string) == ["версия здесь", "второй"])
        #expect(try fixture.store.unresolvedConflicts(ofPage: fixture.pageId).isEmpty)
        #expect(fixture.textView.subviews.compactMap { $0 as? ConflictLabelView }.isEmpty, "Метка снята")
    }

    @Test("«Оставить ту» — в блоке вторая версия, ⌘Z возвращает свою")
    func keepOther() throws {
        let (fixture, conflict) = try fixtureWithConflict()
        try resolve(fixture, conflict, .other)
        #expect(fixture.texts == ["версия с другого Mac", "второй"])
        #expect(try fixture.savedBlocks().map(\.text.string) == ["версия с другого Mac", "второй"])
        #expect(try fixture.store.unresolvedConflicts(ofPage: fixture.pageId).isEmpty)
        fixture.undo()
        #expect(fixture.texts == ["версия здесь", "второй"])
    }

    @Test("«Оставить обе» — две версии двумя блоками подряд")
    func keepBoth() throws {
        let (fixture, conflict) = try fixtureWithConflict()
        try resolve(fixture, conflict, .both)
        #expect(fixture.texts == ["версия здесь", "версия с другого Mac", "второй"])
        #expect(try fixture.savedBlocks().map(\.text.string) == ["версия здесь", "версия с другого Mac", "второй"])
        #expect(try fixture.store.unresolvedConflicts(ofPage: fixture.pageId).isEmpty)
    }
}

@MainActor
@Suite("Место метки «Две версии»")
struct ConflictLabelPlacementTests {
    @Test("Метка у правого края колонки текста, а не далеко за ним (№ 14)")
    func labelHugsColumn() throws {
        let fixture = try EditorFixture([.paragraph("Короткий"), .paragraph("второй")])
        let blockId = fixture.document.blocks[0].id
        try fixture.store.write { tx in
            try tx.recordConflict(blockId: blockId, localVersion: InlineText("Короткий"), remoteVersion: InlineText("Другой"),
                                  remoteDeviceName: "MacBook Air")
        }
        fixture.document.replacePendingConflicts(try fixture.store.unresolvedConflicts(ofPage: fixture.pageId))
        let label = try #require(fixture.textView.subviews.compactMap { $0 as? ConflictLabelView }.first)
        let columnRight = fixture.textView.textContainerOrigin.x + (fixture.textView.textContainer?.size.width ?? 0)
        #expect(label.frame.minX >= columnRight, "налезает на текст: \(label.frame.minX) < \(columnRight)")
        #expect(label.frame.minX <= columnRight + 8, "далеко от колонки: \(label.frame.minX) > \(columnRight + 8)")
    }
}
