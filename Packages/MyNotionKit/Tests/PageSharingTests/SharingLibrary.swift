import Databases
import Foundation
import NotesCore
@testable import PageSharing

/// Заметки для проверок ссылки: опубликованная страница со всем, что может указать наружу, и закрытые страницы рядом.
///
///     Опубликованная (упоминания подстраницы и чужой, ссылка mynotion:// на чужую, ссылка на подстраницу, отметка,
///     │               переключатель, картинка, встроенная база)
///     ├─ Секретная подстраница (картинка) ─ Внучка
///     ├─ В корзине ─ Под корзиной
///     ├─ Шаблон
///     └─ Встроенная база: «Первая строка», «Вторая строка»
///     Чужая страница
final class SharingLibrary: @unchecked Sendable {
    let folder: URL
    let database: AppDatabase
    let store: NotesStore
    let root: UUID
    let child: UUID
    let grandchild: UUID
    let trashed: UUID
    let underTrashed: UUID
    let template: UUID
    let privatePage: UUID
    let inlineDatabase: UUID
    let toggle: UUID
    let image: AttachmentRef
    let childImage: AttachmentRef
    let privateImage: AttachmentRef

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PageSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite"))
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        self.store = store
        func ref(_ name: String) -> AttachmentRef {
            AttachmentRef(name: name, byteCount: 4, contentType: "public.png", sha256: String(repeating: "0", count: 64))
        }
        let (image, childImage, privateImage) = (ref("Картинка.png"), ref("Картинка подстраницы.png"), ref("Закрытая картинка.png"))
        (self.image, self.childImage, self.privateImage) = (image, childImage, privateImage)

        let ids = try store.write { tx throws -> [UUID] in
            let privatePage = try tx.createPage(title: "Чужая страница")
            try Self.append(tx, .image, to: privatePage.id, props: Self.props(privateImage))
            let root = try tx.createPage(title: "Опубликованная", icon: "🚀")
            let child = try tx.createPage(title: "Секретная подстраница", parentId: root.id)
            try Self.append(tx, .paragraph, "Тайный текст", to: child.id)
            try Self.append(tx, .image, to: child.id, props: Self.props(childImage))
            let grandchild = try tx.createPage(title: "Внучка", parentId: child.id)
            let trashed = try tx.createPage(title: "В корзине", parentId: root.id)
            let underTrashed = try tx.createPage(title: "Под корзиной", parentId: trashed.id)
            var template = Page(title: "Шаблон", parentId: root.id, sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date(),
                                isTemplate: true)
            try tx.insertPage(&template)

            let inline = try tx.createPage(title: "Встроенная база", parentId: root.id)
            _ = try tx.saveDatabase(DatabaseSchema(pageId: inline.id, isInline: true))
            let titleProperty = try tx.saveProperty(DatabaseProperty(databaseId: inline.id, name: "Название", kind: .title, sortKey: .between(nil, nil)))
            let site = try tx.saveProperty(DatabaseProperty(databaseId: inline.id, name: "Сайт", kind: .url,
                                                            sortKey: .between(titleProperty.sortKey, nil)))
            var rowKey: FractionalSortKey?
            var rows: [UUID] = []
            for title in ["Первая строка", "Вторая строка"] {
                rowKey = .between(rowKey, nil)
                let row = Page(title: title, parentId: inline.id, sortKey: rowKey!, createdAt: Date(), updatedAt: Date())
                try tx.insertPage(row)
                rows.append(row.id)
            }
            _ = try tx.setCell(rowId: rows[0], propertyId: site.id, value: .string("https://example.com"))

            let mentions = InlineText("См. \u{FFFC} и \u{FFFC}, ещё ссылка", runs: [
                StyledRun(start: 4, length: 1, style: .mention(child.id)),
                StyledRun(start: 8, length: 1, style: .mention(privatePage.id)),
                StyledRun(start: 15, length: 6, style: .link(URL(string: "mynotion://page/\(privatePage.id.uuidString)")!)),
            ])
            try Self.append(tx, .paragraph, text: mentions, to: root.id)
            try Self.append(tx, .pageLink, to: root.id, linked: child.id)
            try Self.append(tx, .checkbox, "Сделано", to: root.id, checked: true)
            let toggle = try Self.append(tx, .toggle, "Переключатель", to: root.id)
            try Self.append(tx, .paragraph, "Внутри переключателя", to: root.id, indent: 1)
            try Self.append(tx, .image, to: root.id, props: Self.props(image))
            try Self.append(tx, .database, to: root.id, linked: inline.id)
            return [root.id, child.id, grandchild.id, trashed.id, underTrashed.id, template.id, privatePage.id, inline.id, toggle.id]
        }
        (root, child, grandchild, trashed, underTrashed, template, privatePage, inlineDatabase, toggle) =
            (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6], ids[7], ids[8])
        try trash(trashed)
    }

    deinit {
        database.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// В корзину, как «Удалить» в окне (`PageTreeOperations` — только с главного потока).
    func trash(_ pageId: UUID) throws {
        try store.write { tx in
            guard var page = try tx.page(pageId) else { return }
            page.trashedAt = Date()
            _ = try tx.updatePage(page)
        }
    }

    func appendParagraph(_ text: String, to pageId: UUID) throws {
        try store.write { tx in try Self.append(tx, .paragraph, text, to: pageId) }
    }

    func setText(_ text: String, ofFirstBlockOn pageId: UUID) throws {
        try store.write { tx in
            var block = try tx.blocks(ofPage: pageId)[0]
            block.text = InlineText(text)
            _ = try tx.updateBlock(block)
        }
    }

    private static func props(_ ref: AttachmentRef) -> BlockProps {
        var props = BlockProps()
        props.attachment = ref
        return props
    }

    @discardableResult
    private static func append(_ tx: NotesTransaction, _ kind: BlockKind, _ string: String = "", text: InlineText? = nil, to pageId: UUID,
                               indent: Int = 0, checked: Bool = false, linked: UUID? = nil, props: BlockProps = .empty) throws -> Block {
        let last = try tx.blocks(ofPage: pageId).last?.sortKey
        return try tx.insertBlock(Block(pageId: pageId, kind: kind, text: text ?? InlineText(string), indent: indent, isChecked: checked,
                                        linkedPageId: linked, sortKey: .between(last, nil), props: props))
    }
}
