import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Виды блоков без своего текста ставит сама страница (TextKit 2 своих видов вложений не создаёт — проба US4):
/// вид стоит поверх своего абзаца, пока абзац в видимой области (с запасом), и снимается за ней; вид с курсором — остаётся.
@MainActor
@Suite("Показ видов блоков", .serialized)
struct BlockViewHostingTests {
    typealias Spec = EditorFixture.Spec

    func paragraphRect(_ fixture: EditorFixture, block index: Int) throws -> NSRect {
        let storage = try #require(fixture.textView.textContentStorage)
        let layoutManager = try #require(fixture.textView.textLayoutManager)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: fixture.textLocation(ofBlock: index)))
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(layoutManager.textLayoutFragment(for: location))
        let origin = fixture.textView.textContainerOrigin
        return fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
    }

    @Test("Вид кода стоит поверх своего абзаца, высотой как строка вложения")
    func viewOverParagraph() throws {
        let fixture = try EditorFixture([.paragraph("До"), Spec(kind: .code, text: "a\nb\nc"), .paragraph("После")])
        fixture.textView.blockViews.update()
        let host = try #require(fixture.textView.blockViews.view(for: fixture.document.blocks[1].id))
        #expect(host.superview === fixture.textView)
        #expect(host.subviews.first is CodeBlockView)
        let paragraph = try paragraphRect(fixture, block: 1)
        #expect(host.frame.minY >= paragraph.minY - 0.5 && host.frame.maxY <= paragraph.maxY + 0.5)
        #expect(abs(host.frame.height - (BlockViewFactories.shared.factory(for: .code)?.height(for: fixture.document.blocks[1], width: host.frame.width) ?? 0)) < 1)
        #expect(host.frame.minX >= fixture.textView.textContainerOrigin.x)
        #expect(fixture.textView.blockViews.view(for: fixture.document.blocks[0].id) == nil, "у абзаца вида нет")
    }

    @Test("Вид за краем видимой области снимается, при прокрутке к нему — ставится; вид с курсором остаётся")
    func lifetimeFollowsVisibility() throws {
        var specs: [Spec] = [Spec(kind: .code, text: "верх")]
        specs += (0..<200).map { .paragraph("Абзац \($0)") }
        specs.append(Spec(kind: .code, text: "низ"))
        let fixture = try EditorFixture(specs)
        let top = fixture.document.blocks[0].id
        let bottom = fixture.document.blocks[201].id
        fixture.textView.blockViews.update()
        #expect(fixture.textView.blockViews.view(for: top) != nil)
        #expect(fixture.textView.blockViews.view(for: bottom) == nil)

        // В невидимом окне высота страницы прикидочная, пока её не разложили целиком.
        let layoutManager = try #require(fixture.textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let bottomRect = try paragraphRect(fixture, block: 201)
        fixture.textView.frame.size.height = max(fixture.textView.frame.height, bottomRect.maxY + 200)
        fixture.textView.scrollToVisible(bottomRect)
        fixture.textView.blockViews.update()
        #expect(fixture.textView.blockViews.view(for: top) == nil)
        let bottomHost = try #require(fixture.textView.blockViews.view(for: bottom))

        // Курсор в коде внизу: прокрутка наверх вид не снимает.
        let code = try #require(bottomHost.subviews.first as? CodeBlockView)
        fixture.window.makeFirstResponder(code.textView)
        fixture.textView.scrollRangeToVisible(NSRange(location: 0, length: 1))
        fixture.textView.blockViews.update()
        #expect(fixture.textView.blockViews.view(for: bottom) === bottomHost)
        #expect(fixture.window.firstResponder === code.textView)
    }

    @Test("Абзац выше вырос — вид съезжает вместе со своим абзацем")
    func followsLayoutChanges() throws {
        let fixture = try EditorFixture([.paragraph("До"), Spec(kind: .code, text: "x")])
        fixture.textView.blockViews.update()
        let host = try #require(fixture.textView.blockViews.view(for: fixture.document.blocks[1].id))
        let before = host.frame.minY
        fixture.placeCaret(inBlock: 0, at: nil)
        fixture.press(#selector(NSResponder.insertNewline(_:)))
        fixture.type("ещё абзац")
        fixture.textView.blockViews.update()
        #expect(host.frame.minY > before + 10)
        #expect(fixture.textView.blockViews.view(for: fixture.document.blocks[2].id) === host)
    }

    /// Прокрутка длинной страницы (замер: 10 000 блоков, p95 ≤ 50 мс): поиск абзацев-вложений идёт только по видимой
    /// части, без раскладки страницы с начала; на странице без вложений — ничего не перебирается.
    @Test("Длинная страница: после прокрутки вниз поиск видов не раскладывает страницу с начала")
    func updateDoesNotLayOutFromStart() throws {
        var specs: [Spec] = (0..<3_000).map { .paragraph("Абзац \($0) с текстом, чтобы строка была подлиннее") }
        specs.append(Spec(kind: .code, text: "низ"))
        let fixture = try EditorFixture(specs)
        let layoutManager = try #require(fixture.textView.textLayoutManager)
        let storage = try #require(fixture.textView.textContentStorage)
        let middle = try #require(storage.location(storage.documentRange.location, offsetBy: fixture.textLocation(ofBlock: 1_500)))
        let before = layoutManager.textLayoutFragment(for: middle)?.state
        // Прокрутка сдвигом видимой области, как колёсиком: виды ищутся при сдвиге, раньше, чем TextKit разложит новое место.
        let clip = try #require(fixture.textView.enclosingScrollView?.contentView)
        fixture.textView.frame.size.height = max(fixture.textView.frame.height, 90_000)
        clip.scroll(to: NSPoint(x: 0, y: 80_000))
        fixture.textView.blockViews.update()
        let after = layoutManager.textLayoutFragment(for: middle)?.state
        #expect(before != .layoutAvailable)
        #expect(after != .layoutAvailable, "update() разложил середину страницы: \(String(describing: before)) → \(String(describing: after))")
    }
}
