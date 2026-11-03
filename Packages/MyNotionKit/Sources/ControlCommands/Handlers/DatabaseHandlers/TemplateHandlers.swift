import ControlProtocol
import Databases
import Foundation
import NotesCore

/// Шаблоны строк базы (004, US6): список, новый, по умолчанию, копия, удаление и шаблон на пустую строку. Шаблон — по
/// названию (без регистра, `ё` = `е`) или id; в таблице и поиске шаблонов нет, только здесь и в «Создать ▾».
enum TemplateHandlers {
    static let all: [String: CommandHandler] = [
        "db.template.list": { session in
            let database = try session.database()
            let list = try session.templateList(of: database.page.id)
            return CommandResult(session.templatesData(list), text: list.templates.map(\.title).joined(separator: "\n"))
        },
        "db.template.add": { session in
            let database = try session.database()
            let id = try session.databases.addRowTemplate(to: database.page.id, title: session.string("title") ?? "")
            session.touch([id])
            return try session.templateResult(id, of: database.page.id, "✓ Шаблон добавлен")
        },
        "db.template.default": { session in
            let database = try session.database()
            if session.flag("none") {
                try session.databases.setDefaultRowTemplate(nil, of: database.page.id)
                return CommandResult(session.templatesData(try session.templateList(of: database.page.id)), text: "✓ По умолчанию — «Пустая»")
            }
            guard let pointer = session.string("template") else { throw CommandCatalog.missing(named: "template", in: session.spec) }
            let template = try session.rowTemplate(pointer, in: database.page.id)
            try session.databases.setDefaultRowTemplate(template.id, of: database.page.id)
            return CommandResult(session.templatesData(try session.templateList(of: database.page.id)),
                                 text: "✓ По умолчанию — «\(template.title)»")
        },
        "db.template.duplicate": { session in
            let (database, template) = try session.databaseTemplate()
            let copy = try session.databases.duplicateRowTemplate(template.id)
            session.touch([copy])
            return try session.templateResult(copy, of: database.page.id, "✓ Копия шаблона «\(template.title)»")
        },
        "db.template.delete": { session in
            let (database, template) = try session.databaseTemplate()
            try session.databases.trashRowTemplate(template.id)
            return CommandResult(session.templatesData(try session.templateList(of: database.page.id)), text: "✓ Шаблон «\(template.title)» удалён")
        },
        "db.template.apply": { session in
            let database = try session.database()
            let row = try session.databaseRefs.row(session.string("row") ?? "", inDatabase: database.page.id)
            let template = try session.rowTemplate(session.string("template") ?? "", in: database.page.id)
            try await session.willWrite(row.id)
            do {
                try session.databases.applyRowTemplate(template.id, toRow: row.id, now: session.host.now)
            } catch NotesStoreError.invalidPage {
                throw ControlError(.invalidValue, "Шаблон кладут только на пустую строку: у «\(row.displayTitle)» уже есть текст или подстраницы",
                                   hint: "Новая строка по шаблону: mynotion db row add --template",
                                   details: ["row": .string(row.id.controlText), "template": .string(template.title)])
            }
            session.touch([row.id])
            return try session.rowResult(row.id, of: database.page.id, "✓ Шаблон «\(template.title)» на строке «\(row.displayTitle)»")
        },
    ]
}

extension CommandSession {
    func templateList(of databaseId: UUID) throws -> RowTemplateList {
        try RowTemplates.list(of: databaseId, in: host.store)
    }

    func templatesData(_ list: RowTemplateList) -> ControlJSON {
        let templates = list.templates.map { templateJSON($0, isDefault: $0.id == list.defaultTemplateId) }
        return ["templates": .array(templates),
                "defaultTemplate": list.defaultTemplateId.flatMap { id in templates.first { $0["id"]?.string == id.controlText } } ?? .null]
    }

    func templateResult(_ templateId: UUID, of databaseId: UUID, _ text: String) throws -> CommandResult {
        let list = try templateList(of: databaseId)
        guard let template = list.templates.first(where: { $0.id == templateId }) else { throw NotesStoreError.pageNotFound(templateId) }
        return CommandResult(["template": templateJSON(template, isDefault: template.id == list.defaultTemplateId)], text: text)
    }

    private func templateJSON(_ template: RowTemplate, isDefault: Bool) -> ControlJSON {
        ["id": .string(template.id.controlText), "title": .string(template.title),
         "icon": template.icon.map { .string($0) } ?? .null, "isDefault": .bool(isDefault)]
    }

    func databaseTemplate() throws -> (ResolvedDatabase, RowTemplate) {
        let database = try database()
        return (database, try rowTemplate(string("template") ?? "", in: database.page.id))
    }

    /// Шаблон базы по id или названию.
    func rowTemplate(_ pointer: String, in databaseId: UUID) throws -> RowTemplate {
        let templates = try templateList(of: databaseId).templates
        let text = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text), let template = templates.first(where: { $0.id == id }) { return template }
        let key = PagePath.normalized(text)
        let named = templates.filter { PagePath.normalized($0.title) == key }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw ControlError(.templateNotFound, "Шаблонов «\(text)» несколько (\(named.count)): укажите id", hint: "Шаблоны: mynotion db template list",
                               details: ["candidates": .array(named.map { ["id": .string($0.id.controlText), "title": .string($0.title)] })])
        }
        throw ControlError(.templateNotFound, "У базы нет шаблона «\(text)»",
                           hint: templates.isEmpty ? "Шаблонов нет. Новый: mynotion db template add" : "Шаблоны: " + templates.map(\.title).joined(separator: ", "),
                           details: ["template": .string(text), "allowed": .array(templates.map { .string($0.title) })])
    }
}
