import ControlProtocol
import Databases
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Свойство кодеков (contracts/block-json.md): `decode(encode(x)) == x`.
@Suite struct CodecTests {
    static let pageId = UUID()
    static let otherPage = UUID()
    static let image = AttachmentRef(name: "cat.png", byteCount: 10, contentType: "public.png", sha256: "ab")
    static let mention = DateMention(start: "2026-10-24T09:00", includesTime: true, timeZone: "Asia/Makassar",
                                     reminder: .init(fireAt: Date(timeIntervalSince1970: 1_800_000_000)))
    static let titles: MentionTitles = { $0 == otherPage ? (title: "Проекты", icon: "🚀") : nil }
    static let attachments: AttachmentLookup = { $0 == image.id ? image : nil }

    /// Строка со всеми видами оформления.
    static var styledText: InlineText {
        let string = "жирный курсив зачёркнутый код подчёркнутый красный жёлтый ссылка \u{FFFC} \u{FFFC} \u{FFFC} конец"
        let units = Array(string.utf16)
        func range(_ word: String, from: Int = 0) -> (Int, Int) {
            let ns = string as NSString
            let found = ns.range(of: word, range: NSRange(location: from, length: units.count - from))
            return (found.location, found.length)
        }
        var runs: [StyledRun] = []
        func add(_ word: String, _ style: InlineStyle) {
            let (start, length) = range(word)
            runs.append(StyledRun(start: start, length: length, style: style))
        }
        add("жирный", .bold)
        add("курсив", .italic)
        add("зачёркнутый", .strikethrough)
        add("код", .code)
        add("подчёркнутый", .underline)
        add("красный", .textColor(.red))
        add("жёлтый", .backgroundColor(.yellow))
        add("ссылка", .link(URL(string: "https://example.com/a")!))
        let atoms = units.enumerated().filter { $0.element == InlineText.objectReplacementCharacter }.map(\.offset)
        runs.append(StyledRun(start: atoms[0], length: 1, style: .mention(otherPage)))
        runs.append(StyledRun(start: atoms[1], length: 1, style: .date(mention)))
        runs.append(StyledRun(start: atoms[2], length: 1, style: .equation("x^2")))
        return InlineText(string, runs: runs).normalized()
    }

    // MARK: Строка

    @Test func richRoundTrip() throws {
        let text = Self.styledText
        let json = RichTextJSON.encode(text)
        #expect(json["string"] == .string(text.string))
        #expect(json["runs"]?.array?.contains { $0["style"] == "bold" } == true)
        #expect(json["runs"]?.array?.contains { $0["style"] == .string("mention:\(Self.otherPage.uuidString.lowercased())") } == true)
        #expect(try RichTextJSON.decode(json) == text)
    }

    @Test func richRejectsUnknownStyle() {
        #expect(throws: ControlError.self) {
            try RichTextJSON.decode(["string": "аб", "runs": [["from": 0, "to": 1, "style": "blink"]]])
        }
    }

    @Test func markdownRoundTripEachStyle() {
        let text = Self.styledText
        let markdown = InlineMarkdownCodec.markdown(text, titles: Self.titles)
        #expect(markdown.contains("**жирный**"))
        #expect(markdown.contains("[🚀 Проекты](mynotion://page/\(Self.otherPage.uuidString.lowercased()))"))
        #expect(InlineMarkdownCodec.inlineText(markdown) == text)
    }

    @Test func markdownPlainTextStaysPlain() {
        #expect(InlineMarkdownCodec.inlineText("Купить молоко") == InlineText("Купить молоко"))
        #expect(InlineMarkdownCodec.inlineText("Купить **молоко**") == InlineText("Купить молоко", runs: [StyledRun(start: 7, length: 6, style: .bold)]))
    }

    // MARK: Страница

    @Test func pageRoundTrip() throws {
        var page = Page(id: Self.pageId, title: "Встреча", icon: "🚀", parentId: Self.otherPage, sortKey: .between(nil, nil), createdAt: Date(timeIntervalSince1970: 1_800_000_000), updatedAt: Date(timeIntervalSince1970: 1_800_000_100))
        page.cover = PageCover(source: .file(Self.image), offset: 0.3)
        page.isFullWidth = true
        page.isTemplate = true
        let json = PageJSON.encode(page, kind: .page, path: ["Проекты", "Встреча"], hasChildren: true)
        #expect(json["id"] == .string(Self.pageId.uuidString.lowercased()))
        #expect(json["path"] == ["Проекты", "Встреча"])
        #expect(json["cover"]?["attachmentId"] == .string(Self.image.id.uuidString.lowercased()))
        #expect(json["inTrash"] == false)
        let appearance = try PageJSON.appearance(json, attachments: Self.attachments)
        #expect(appearance == PageAppearance(title: page.title, icon: page.icon, cover: page.cover, isFullWidth: true, isSmallText: false))
        let gallery = PageCover(source: .gallery("gradient-3"), offset: 0.5)
        #expect(try PageJSON.cover(PageJSON.encode(gallery), attachments: Self.attachments) == gallery)
        #expect(try PageJSON.cover(.null, attachments: Self.attachments) == nil)
    }

    // MARK: Блок

    static func sample(_ kind: BlockKind) -> Block {
        var block = Block(pageId: pageId, kind: kind, sortKey: .between(nil, nil))
        switch kind {
        case .paragraph, .heading1, .heading2, .heading3, .quote, .bulletItem, .numberedItem, .toggle, .callout, .checkbox:
            block.text = styledText
            block.color = BlockColor(text: .red, background: .gray)
            block.indent = kind == .bulletItem ? 2 : 0
            block.isChecked = kind == .checkbox
        case .code: block.text = InlineText("let x = 1")
        case .equation: block.text = InlineText("E = mc^2")
        case .pageLink, .database: block.linkedPageId = otherPage
        default: break
        }
        block.props = BlockProps.defaults(for: kind)
        switch kind {
        case .callout: block.props.values["icon"] = "💡"
        case .code: block.props.values["language"] = "swift"
        case .image, .file, .video:
            block.props.values["attachment"] = try! JSONValue(encoding: image)
            block.props.values["width"] = .number(0.5)
        case .bookmark: block.props.values = ["url": "https://example.com", "title": "Пример", "description": "Описание"]
        case .table: block.props.values = ["hasHeaderRow": .bool(true), "hasHeaderColumn": .bool(false)]
        case .column: block.props.values["widthRatio"] = .number(0.4)
        case .toggle, .heading1: block.props.values["expanded"] = .bool(true)
        default: break
        }
        return block
    }

    @Test(arguments: BlockKind.allCases)
    func blockRoundTrip(_ kind: BlockKind) throws {
        let block = Self.sample(kind)
        let json = BlockJSON.encode(block, titles: Self.titles)
        #expect(json["kind"] == .string(kind.rawValue))
        let decoded = try BlockJSON.decode(json, pageId: block.pageId, sortKey: block.sortKey, containerId: block.containerId)
        #expect(decoded.id == block.id)
        #expect(decoded.kind == block.kind)
        #expect(decoded.text == block.text)
        #expect(decoded.indent == block.indent)
        #expect(decoded.isChecked == block.isChecked)
        #expect(decoded.linkedPageId == block.linkedPageId)
        #expect(decoded.color == block.color)
        #expect(decoded.props == block.props)
    }

    @Test func blockFromMarkdownText() throws {
        let json: ControlJSON = ["kind": "checkbox", "text": "Купить **молоко**", "checked": true]
        let block = try BlockJSON.decode(json, pageId: Self.pageId, sortKey: .between(nil, nil), containerId: nil)
        #expect(block.text == InlineText("Купить молоко", runs: [StyledRun(start: 7, length: 6, style: .bold)]))
        #expect(block.isChecked)
    }

    @Test func blockRejectsUnknownKindAndColor() {
        #expect(throws: ControlError.self) {
            try BlockJSON.decode(["kind": "marquee"], pageId: Self.pageId, sortKey: .between(nil, nil), containerId: nil)
        }
        #expect(throws: ControlError.self) {
            try BlockJSON.decode(["kind": "paragraph", "color": ["text": "ultraviolet"]], pageId: Self.pageId, sortKey: .between(nil, nil),
                                 containerId: nil)
        }
    }

    // MARK: Ячейки

    static let databaseId = UUID()
    static func property(_ kind: PropertyKind, _ name: String) -> DatabaseProperty {
        DatabaseProperty(databaseId: databaseId, name: name, kind: kind, sortKey: .between(nil, nil))
    }

    static let properties: [DatabaseProperty] = PropertyKind.all.map { property($0, $0 == .title ? "Название" : "П-\($0.rawValue)") }
    static func named(_ kind: PropertyKind) -> DatabaseProperty { properties.first { $0.kind == kind }! }
    static let options: [SelectOption] = [
        SelectOption(propertyId: named(.select).id, name: "Срочно", color: .red, sortKey: .between(nil, nil)),
        SelectOption(propertyId: named(.multiSelect).id, name: "A", sortKey: .between(nil, nil)),
        SelectOption(propertyId: named(.multiSelect).id, name: "B", sortKey: .between(.between(nil, nil), nil)),
        SelectOption(propertyId: named(.status).id, name: "Готово", sortKey: .between(nil, nil), statusGroup: .complete),
    ]
    static let catalog = DatabaseCatalog(databaseId: databaseId, properties: properties, options: options)
    static var context: CellContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Makassar")!
        return CellContext(catalog: catalog, calendar: calendar, attachments: attachments, titles: titles)
    }

    static func option(_ name: String) -> UUID { options.first { $0.name == name }!.id }

    /// Сохранённое значение каждого типа с ячейкой.
    static let stored: [(PropertyKind, JSONValue)] = [
        (.text, try! JSONValue(encoding: styledText)),
        (.number, .number(42.5)),
        (.select, .string(option("Срочно").uuidString.lowercased())),
        (.multiSelect, .array([.string(option("A").uuidString.lowercased()), .string(option("B").uuidString.lowercased())])),
        (.status, .string(option("Готово").uuidString.lowercased())),
        (.date, DateCellValue(day: DateParts(year: 2026, month: 10, day: 24), timeZone: "Asia/Makassar").json),
        (.date, ["start": "2026-10-24T09:30", "end": "2026-10-25T10:00", "hasTime": true, "timeZone": "Europe/Moscow", "reminder": "hour1"]),
        (.checkbox, .bool(true)),
        (.url, .string("https://example.com")),
        (.email, .string("a@b.c")),
        (.phone, .string("+7 900")),
        (.files, .array([["attachment": try! JSONValue(encoding: image)], ["url": "https://example.com/f.pdf", "name": "f.pdf"]])),
    ]

    @Test(arguments: 0..<12)
    func cellRoundTrip(_ index: Int) throws {
        let (kind, value) = Self.stored[index]
        let property = Self.named(kind)
        let json = CellValueJSON.encode(value, of: property, in: Self.context)
        #expect(try CellValueJSON.decode(json, for: property, in: Self.context) == .value(value))
    }

    @Test func cellNamesAreReadable() {
        #expect(CellValueJSON.encode(Self.stored[2].1, of: Self.named(.select), in: Self.context) == "Срочно")
        #expect(CellValueJSON.encode(Self.stored[3].1, of: Self.named(.multiSelect), in: Self.context) == ["A", "B"])
        #expect(CellValueJSON.encode(Self.stored[5].1, of: Self.named(.date), in: Self.context) == "2026-10-24")
        #expect(CellValueJSON.encode(Self.stored[0].1, of: Self.named(.text), in: Self.context).string?.contains("**жирный**") == true)
    }

    @Test func titleAndRelationAndNull() throws {
        #expect(try CellValueJSON.decode("Отчёт", for: Self.named(.title), in: Self.context) == .title("Отчёт"))
        #expect(CellValueJSON.encode(.string("Отчёт"), of: Self.named(.title), in: Self.context) == "Отчёт")
        let rowId = UUID()
        let related: JSONValue = .array([["id": .string(rowId.uuidString.lowercased()), "title": "Строка"]])
        let encoded = CellValueJSON.encode(related, of: Self.named(.relation), in: Self.context)
        #expect(try CellValueJSON.decode(encoded, for: Self.named(.relation), in: Self.context) == .relation([rowId.uuidString.lowercased()]))
        #expect(try CellValueJSON.decode(["Строка"], for: Self.named(.relation), in: Self.context) == .relation(["Строка"]))
        #expect(try CellValueJSON.decode(.null, for: Self.named(.number), in: Self.context) == .clear)
    }

    @Test func missingOptionsAreReported() throws {
        #expect(try CellValueJSON.decode("Новый", for: Self.named(.select), in: Self.context) == .newOptions(existing: [], missing: ["Новый"]))
        #expect(try CellValueJSON.decode(["A", "Новый"], for: Self.named(.multiSelect), in: Self.context)
            == .newOptions(existing: [Self.option("A")], missing: ["Новый"]))
        #expect(try CellValueJSON.decode("срочно", for: Self.named(.select), in: Self.context) == .value(Self.stored[2].1))
        do {
            _ = try CellValueJSON.decode("Нет такого", for: Self.named(.status), in: Self.context)
            Issue.record("статус без варианта прошёл")
        } catch {
            #expect(error.code == .optionNotFound)
        }
    }

    @Test(arguments: [PropertyKind.rollup, .formula, .createdTime, .lastEditedTime, .uniqueId])
    func readOnlyKindsRefuseWrites(_ kind: PropertyKind) {
        do {
            _ = try CellValueJSON.decode("x", for: Self.named(kind), in: Self.context)
            Issue.record("записалось в \(kind)")
        } catch {
            #expect(error.code == .readOnlyProperty)
        }
    }

    @Test func invalidValueExplainsItself() {
        do {
            _ = try CellValueJSON.decode("сорок два", for: Self.named(.number), in: Self.context)
            Issue.record("текст стал числом")
        } catch {
            #expect(error.code == .invalidValue)
            #expect(error.details?["property"] == "П-number")
            #expect(error.details?["type"] == "number")
            #expect(error.details?["expected"]?.string != nil)
            #expect(error.details?["example"] != nil)
        }
        #expect(throws: ControlError.self) { try CellValueJSON.decode("завтра", for: Self.named(.date), in: Self.context) }
        #expect(throws: ControlError.self) { try CellValueJSON.decode(1, for: Self.named(.checkbox), in: Self.context) }
    }

    // MARK: Вид

    @Test func filterRoundTripWithNames() throws {
        let status = Self.named(.status), date = Self.named(.date), tags = Self.named(.multiSelect)
        let filter = FilterNode.and([
            .condition(FilterCondition(propertyId: status.id, op: .isNot, value: .string(Self.option("Готово").uuidString.lowercased()))),
            .or([
                .condition(FilterCondition(propertyId: date.id, op: .isRelativeToToday, value: "thisWeek")),
                .condition(FilterCondition(propertyId: tags.id, op: .contains, value: .string(Self.option("A").uuidString.lowercased()))),
            ]),
        ])
        let json = ViewJSON.encode(filter, in: Self.catalog)
        #expect(json["and"]?[0]?["property"] == "П-status")
        #expect(json["and"]?[0]?["value"] == "Готово")
        #expect(json["and"]?[0]?["propertyId"] == .string(status.id.uuidString.lowercased()))
        #expect(try ViewJSON.filter(json, in: Self.catalog) == filter)
        let byName: ControlJSON = ["and": [["property": "п-status", "operator": "isNot", "value": "Готово"],
                                           ["or": [["property": "П-date", "operator": "isRelativeToToday", "value": "thisWeek"],
                                                   ["property": "П-multiSelect", "operator": "contains", "value": "A"]]]]]
        #expect(try ViewJSON.filter(byName, in: Self.catalog) == filter)
    }

    @Test func filterRejectsWrongOperatorAndProperty() {
        do {
            _ = try ViewJSON.filter(["property": "П-number", "operator": "isBefore", "value": 1], in: Self.catalog)
            Issue.record("неподходящее условие прошло")
        } catch {
            #expect(error.code == .invalidValue)
            #expect(error.details?["allowed"]?.array?.contains("greaterThan") == true)
        }
        do {
            _ = try ViewJSON.filter(["property": "Нет", "operator": "is", "value": 1], in: Self.catalog)
            Issue.record("неизвестное свойство прошло")
        } catch {
            #expect(error.code == .propertyNotFound)
        }
    }

    @Test func sortAndGroupRoundTrip() throws {
        let sorts = [SortSpec(propertyId: Self.named(.date).id, ascending: true), SortSpec(propertyId: Self.named(.number).id, ascending: false)]
        let sortJSON = ViewJSON.encode(sorts, in: Self.catalog)
        #expect(sortJSON[1]?["direction"] == "descending")
        #expect(sortJSON[0]?["property"] == "П-date")
        #expect(try ViewJSON.sorts(sortJSON, in: Self.catalog) == sorts)
        #expect(try ViewJSON.sorts([["property": "П-date", "direction": "ascending"]], in: Self.catalog) == [sorts[0]])
        let group = GroupSettings(propertyId: Self.named(.status).id, groupSort: .alphabetical, hideEmpty: false)
        let groupJSON = ViewJSON.encode(group, in: Self.catalog)
        #expect(groupJSON["property"] == "П-status")
        #expect(groupJSON["sort"] == "alphabetical")
        #expect(try ViewJSON.group(groupJSON, in: Self.catalog) == group)
        #expect(try ViewJSON.group(.null, in: Self.catalog) == nil)
    }
}
