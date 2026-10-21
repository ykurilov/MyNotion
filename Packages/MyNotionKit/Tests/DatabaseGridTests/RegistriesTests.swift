import Foundation
import Testing
@testable import DatabaseGrid
@testable import DatabaseRowPage
@testable import DatabaseViewBar
@testable import NotesCore

/// Реестры «файл на пункт» (T018, plan.md, Structure Decision): истории добавляют файлы, а не правят общие списки.
/// Порядок — contracts/database-ui.md и contracts/property-types.md, в каком бы порядке ни пришли описатели.
@MainActor
@Suite("Реестры баз")
struct RegistriesTests {
    @Test("Типы ячеек: все 18, у каждого значок шапки и способ правки")
    func cellKinds() {
        #expect(Set(CellKind.all.map(\.kind)) == Set(PropertyKind.all))
        #expect(CellKind.all.count == 18)
        #expect(CellKind.for(.title).symbol == "textformat" && CellKind.for(.checkbox).editing == .toggle)
        #expect(CellKind.for(.select).editing == .popup && CellKind.for(.text).editing == .inPlace && CellKind.for(.formula).editing == .none)
    }

    @Test("Список типов «+» и «Сменить тип» — строки по две, как у Notion; ID серый, если в базе уже есть")
    func typePicker() {
        let rows = PropertyTypePicker.rows(existingKinds: [.title, .uniqueId])
        #expect(rows.map { $0.map(\.kind) } == [
            [.text, .number], [.select, .multiSelect], [.status, .date], [.files, .checkbox], [.url, .phone], [.email],
            [], [.relation, .rollup], [.formula, .uniqueId], [], [.createdTime, .lastEditedTime],
        ])
        #expect(rows[8][1].isEnabled == false && rows[8][0].isEnabled)
        #expect(PropertyTypePicker.rows(existingKinds: [], matching: "дат").flatMap { $0 }.map(\.kind) == [.date])
    }

    @Test("Меню колонки — порядок контракта, разделители между группами; пункт без обработчика не показывается")
    func columnMenu() {
        let items = PropertyMenuItem.all.shuffled()
        let all = Set(PropertyMenuSlot.allCases)
        #expect(PropertyMenu.titles(items: items, handled: all) == [
            "Изменить свойство", "Сменить тип", "—", "Фильтр", "Сортировка", "Группировка", "Посчитать", "Скрыть", "Переносить текст", "—",
            "Вставить слева", "Вставить справа", "Дублировать свойство", "Удалить свойство",
        ])
        #expect(PropertyMenu.titles(items: items, handled: [.editProperty, .changeType, .delete]) == ["Изменить свойство", "Сменить тип", "—", "Удалить свойство"])
    }

    @Test("Панель «Изменить свойство»: имя, тип, настройки типа, перенос, дублировать, удалить; настройки — только у своих типов")
    func settingsPanel() {
        #expect(PropertySettingsPanel.sections(for: .text).map(\.slot) == [.name, .type, .wrapText, .duplicate, .delete])
        #expect(PropertySettingsPanel.sections(for: .number).map(\.slot) == [.name, .type, .typeSettings, .wrapText, .duplicate, .delete])
        #expect(PropertySettingsPanel.sections(for: .title).map(\.slot) == [.name, .wrapText], "название не меняет тип и не удаляется")
    }

    @Test("Кнопки строки вида: Фильтр, Сортировка, Поиск, ⤢ (только у встроенной), Настройки вида, Создать")
    func viewBar() {
        #expect(ViewBarItem.ordered(ViewBarItem.all.shuffled(), isInline: true).map(\.slot) == [.filter, .sort, .search, .openFullPage, .settings, .create])
        #expect(ViewBarItem.ordered(ViewBarItem.all, isInline: false).map(\.slot) == [.filter, .sort, .search, .settings, .create])
    }

    @Test("Меню строки: поиск действия, избранное, иконка, свойство, открыть в, дублировать, переместить, удалить, подпись")
    func rowMenu() {
        #expect(RowMenuItem.ordered(RowMenuItem.all.shuffled()).map(\.slot)
                == [.findAction, .favorite, .changeIcon, .editProperty, .openIn, .duplicate, .moveTo, .trash, .footer])
        #expect(RowMenuItem.all.first { $0.slot == .duplicate }?.hint == "⌘D")
    }

    @Test("Места страницы строки: свойства под названием, «+ Добавить свойство», шаблоны в пустом теле, кнопки просмотра")
    func rowPagePlaces() {
        #expect(RowPagePlace.ordered(RowPagePlace.all.shuffled()).map(\.slot) == [.properties, .addProperty, .emptyBodyTemplates, .peekControls])
    }
}
