import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Смена типа (contracts/property-types.md, «Смена типа»): что становится значением в новом типе.
@Suite("Смена типа")
struct TypeChangeTests {
    func convert(_ value: JSONValue?, from: PropertyContext, to kind: PropertyKind, options: [SelectOption] = []) -> TypeChange.Result {
        TypeChange.convert(value, from: from, to: TypeFixture.context(kind, options: options))
    }

    @Test("Любой тип → текст — текст показа как в CSV; связь → названия через «, »")
    func toText() {
        #expect(convert(.number(1234.5), from: TypeFixture.context(.number), to: .text) == .value(TypeFixture.text("1234.5")))
        #expect(convert(.bool(true), from: TypeFixture.context(.checkbox), to: .text) == .value(TypeFixture.text("Yes")))
        let links: JSONValue = [["id": "a", "title": "Банк", "path": "x.md"], ["id": "b", "title": "Ремонт"]]
        #expect(convert(links, from: TypeFixture.context(.relation), to: .text) == .value(TypeFixture.text("Банк, Ремонт")))
    }

    @Test("Текст → число, дата, флажок, ссылка; не разобралось — пусто")
    func fromText() {
        let text = TypeFixture.context(.text)
        #expect(convert(TypeFixture.text("3,5"), from: text, to: .number) == .value(.number(3.5)))
        #expect(convert(TypeFixture.text("abc"), from: text, to: .number) == .value(nil))
        #expect(convert(TypeFixture.text("2026-10-21"), from: text, to: .date) == .value(TypeFixture.date("2026-10-21")))
        #expect(convert(TypeFixture.text("да"), from: text, to: .checkbox) == .value(.bool(true)))
        #expect(convert(.number(0), from: TypeFixture.context(.number), to: .checkbox) == .value(.bool(false)))
        #expect(convert(TypeFixture.text("https://a.b"), from: text, to: .url) == .value(.string("https://a.b")))
        #expect(convert(.string("me@a.b"), from: TypeFixture.context(.email), to: .text) == .value(TypeFixture.text("me@a.b")))
    }

    @Test("Текст → выбор / множественный выбор — названия вариантов; между выборами — варианты переносятся")
    func options() {
        #expect(convert(TypeFixture.text("Срочно"), from: TypeFixture.context(.text), to: .select) == .optionNames(["Срочно"]))
        #expect(convert(TypeFixture.text("a, b"), from: TypeFixture.context(.text), to: .multiSelect) == .optionNames(["a", "b"]))
        let multi = TypeFixture.context(.multiSelect, options: TypeFixture.options)
        let both: JSONValue = [TypeFixture.id(TypeFixture.options[2]), TypeFixture.id(TypeFixture.options[0])]
        #expect(convert(both, from: multi, to: .select) == .optionNames(["Высокий"]), "в выбор — первый")
        #expect(convert(TypeFixture.id(TypeFixture.options[1]), from: TypeFixture.context(.select, options: TypeFixture.options), to: .status)
                == .optionNames(["Средний"]))
    }

    @Test("Любой → связь, сводка, формула, создано, изменено, ID — значения не переносятся")
    func toComputed() {
        for kind in [PropertyKind.relation, .rollup, .formula, .createdTime, .lastEditedTime, .uniqueId] {
            #expect(convert(TypeFixture.text("x"), from: TypeFixture.context(.text), to: kind) == .value(nil))
        }
    }
}
