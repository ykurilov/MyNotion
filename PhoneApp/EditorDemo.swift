import NotesCore
import PhonePageEditor
import SwiftUI
import UIKit

/// Временный показ редактора страницы (этап 1А, до оболочки с деревом страниц): запуск с `--editor-demo` открывает
/// страницу со всеми блоками этапа 1 и оформлением в строке; `--editor-demo-keyboard` — ещё и курсор в задаче,
/// с открытой клавиатурой. База — своя, во временной папке, пересоздаётся при каждом запуске.
enum EditorDemo {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--editor-demo") } }
    static var opensKeyboard: Bool { ProcessInfo.processInfo.arguments.contains("--editor-demo-keyboard") }
}

struct EditorDemoView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        let navigation = UINavigationController()
        do {
            let demo = try EditorDemoLibrary()
            context.coordinator.library = demo
            navigation.viewControllers = [try demo.screen(for: demo.pageId, in: navigation)]
            if EditorDemo.opensKeyboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { focusTask(in: navigation.view) }
            }
        } catch {
            let failed = UIViewController()
            let label = UILabel()
            label.text = "Демо не открылось: \(error.localizedDescription)"
            label.numberOfLines = 0
            failed.view = label
            navigation.viewControllers = [failed]
        }
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var library: EditorDemoLibrary?
    }

    /// Курсор — в конец задачи «Купить молоко», как будто её коснулись пальцем.
    private func focusTask(in view: UIView) {
        if let textView = view as? UITextView, textView.text.hasPrefix("Купить") {
            textView.becomeFirstResponder()
            textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
            return
        }
        view.subviews.forEach(focusTask)
    }
}

/// База демо: страница со всеми блоками этапа 1, подстраница и блоки, которых iPhone пока не показывает.
@MainActor
final class EditorDemoLibrary {
    let openDocuments: OpenDocuments
    let pageId: UUID

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditorDemo", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite"))
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: DeviceIdentity.deviceId()))
        pageId = try store.write { tx in try Self.fill(tx) }
        openDocuments = OpenDocuments(store: store)
    }

    func screen(for pageId: UUID, in navigation: UINavigationController) throws -> UIViewController {
        try PhonePageViewController(pageId: pageId, openDocuments: openDocuments) { [weak self, weak navigation] linked in
            guard let self, let navigation, let screen = try? self.screen(for: linked, in: navigation) else { return }
            navigation.pushViewController(screen, animated: true)
        }
    }

    private static func fill(_ tx: NotesTransaction) throws -> UUID {
        let page = try tx.createPage(title: "Демо редактора", icon: "📝")
        let subpage = try tx.createPage(title: "Планы на неделю", icon: "🗓️", parentId: page.id)
        for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
        var key: FractionalSortKey?
        func add(_ kind: BlockKind, _ text: InlineText = .empty, indent: Int = 0, checked: Bool = false, link: UUID? = nil,
                 props: BlockProps = .empty) throws {
            key = .between(key, nil)
            _ = try tx.insertBlock(Block(pageId: page.id, kind: kind, text: text, indent: indent, isChecked: checked,
                                         linkedPageId: link, sortKey: key!, props: props))
        }
        func styled(_ parts: [(String, [InlineStyle])]) -> InlineText {
            var string = ""
            var runs: [StyledRun] = []
            for (part, styles) in parts {
                let start = string.utf16.count
                string += part
                runs += styles.map { StyledRun(start: start, length: part.utf16.count, style: $0) }
            }
            return InlineText(string, runs: runs).normalized()
        }
        let today = Date().formatted(.iso8601.year().month().day())

        try add(.heading1, InlineText("Заголовок первого уровня"))
        try add(.paragraph, styled([("Текст с ", []), ("жирным", [.bold]), (", ", []), ("курсивом", [.italic]), (", ", []),
                                    ("зачёркнутым", [.strikethrough]), (", ", []), ("подчёркнутым", [.underline]), (" и ", []),
                                    ("кодом", [.code]), (". Ссылка на ", []), ("сайт", [.link(URL(string: "https://kurilov.cloud")!)]),
                                    (", ", []), ("красный текст", [.textColor(.red)]), (" и ", []),
                                    ("жёлтый фон", [.backgroundColor(.yellow)]), (".", [])]))
        try add(.paragraph, styled([("Упоминание ", []), ("\u{FFFC}", [.mention(subpage.id)]), (", дата ", []),
                                    ("\u{FFFC}", [.date(DateMention(start: today, includesTime: false, timeZone: TimeZone.current.identifier))]),
                                    (" и формула ", []), ("\u{FFFC}", [.equation("E = mc^2")]), (".", [])]))
        try add(.heading2, InlineText("Списки"))
        try add(.bulletItem, InlineText("Первый пункт"))
        try add(.bulletItem, InlineText("Вложенный пункт"), indent: 1)
        try add(.bulletItem, InlineText("Ещё глубже"), indent: 2)
        try add(.numberedItem, InlineText("Шаг один"))
        try add(.numberedItem, InlineText("Шаг два"))
        try add(.numberedItem, InlineText("Подшаг"), indent: 1)
        try add(.heading3, InlineText("Задачи"))
        try add(.checkbox, InlineText("Купить молоко"))
        try add(.checkbox, InlineText("Позвонить маме"), checked: true)
        try add(.quote, InlineText("Цитата: простое лучше сложного."))
        try add(.toggle, InlineText("Раскрывающийся список"))
        try add(.paragraph, InlineText("Спрятанный внутри текст"), indent: 1)
        try add(.divider)
        try add(.pageLink, link: subpage.id)
        try add(.callout, InlineText("Выноска пока только для чтения"), props: BlockProps.defaults(for: .callout))
        try add(.code, InlineText("print(\"Привет\")"), props: BlockProps.defaults(for: .code))
        try add(.paragraph)
        return page.id
    }
}
