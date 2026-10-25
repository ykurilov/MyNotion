import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import Proofreading

/// Исправитель для тестов: отвечает по правилу `fix` (или ждёт отмены, если `fix` — nil).
private struct FakeProofreader: TextProofreader {
    var fix: (@Sendable (String) throws -> String)?
    func proofread(_ text: String) async throws -> String {
        guard let fix else {
            try await Task.sleep(for: .seconds(60))
            return text
        }
        return try fix(text)
    }
}

private let typos: @Sendable (String) -> String = {
    $0.replacingOccurrences(of: "превет", with: "привет").replacingOccurrences(of: "дила", with: "дела")
}

@MainActor
@Suite("«Исправить ошибки»: окно правок и замена")
struct ProofreadTests {
    /// Страница после первого оборота цикла событий: фокус в тексте ставится там, и выделение после него не сбивается.
    private func open(_ specs: [EditorFixture.Spec]) async throws -> EditorFixture {
        let fixture = try EditorFixture(specs)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        return fixture
    }

    /// Ждёт, пока окно уйдёт из «Проверяю…».
    private func waitForAnswer(_ fixture: EditorFixture) async {
        for _ in 0..<200 where fixture.textView.proofreading.state == .checking { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func selectAll(blocks range: ClosedRange<Int>, _ fixture: EditorFixture) {
        let start = fixture.textLocation(ofBlock: range.lowerBound)
        let end = fixture.textLocation(ofBlock: range.upperBound) + (fixture.document.blocks[range.upperBound].text.string as NSString).length
        fixture.textView.setSelectedRange(NSRange(location: start, length: end - start))
    }

    @Test("Выделение через два блока → правки по словам → «Заменить» → один шаг ⌘Z возвращает всё")
    func replaceAndUndo() async throws {
        let fixture = try await open([.paragraph("превет всем"), .bullet("как дила")])
        selectAll(blocks: 0...1, fixture)
        fixture.textView.proofreading.start(with: FakeProofreader(fix: typos))
        #expect(fixture.textView.proofreading.state == .checking)
        await waitForAnswer(fixture)
        guard case .corrections(let pieces) = fixture.textView.proofreading.state else {
            Issue.record("Нет правок: \(String(describing: fixture.textView.proofreading.state))")
            return
        }
        #expect(pieces.contains(WordDiffPiece(.removed, "превет")))
        #expect(pieces.contains(WordDiffPiece(.inserted, "привет")))
        #expect(fixture.textView.proofreading.panelView?.isReplaceVisible == true)

        fixture.press(#selector(NSResponder.insertNewline(_:)))
        #expect(fixture.texts == ["привет всем", "как дела"])
        #expect(fixture.kinds == [.paragraph, .bulletItem])
        #expect(!fixture.textView.proofreading.isShown)
        #expect(fixture.textView.selectedRange().length > 0, "Исправленный текст остаётся выделенным")

        fixture.undo()
        #expect(fixture.texts == ["превет всем", "как дила"])
    }

    @Test("Часть блока: правится только выделенное, остальное и оформление на месте")
    func partOfBlock() async throws {
        let fixture = try await open([.paragraph("превет и снова превет")])
        fixture.select(inBlock: 0, "и снова превет")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: typos))
        await waitForAnswer(fixture)
        fixture.step { fixture.textView.proofreading.replace() }
        #expect(fixture.texts == ["превет и снова привет"])
    }

    @Test("Без ошибок — «Ошибок не найдено», текст не меняется")
    func noErrors() async throws {
        let fixture = try await open([.paragraph("Всё хорошо.")])
        fixture.select(inBlock: 0, "Всё хорошо.")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: { $0 }))
        await waitForAnswer(fixture)
        #expect(fixture.textView.proofreading.state == .noErrors)
        #expect(fixture.textView.proofreading.panelView?.isReplaceVisible == false)
        fixture.press(#selector(NSResponder.insertNewline(_:)))
        #expect(!fixture.textView.proofreading.isShown)
        #expect(fixture.texts == ["Всё хорошо."])
    }

    @Test("Ошибка исправителя — понятное сообщение по-русски")
    func failure() async throws {
        let fixture = try await open([.paragraph("превет")])
        fixture.select(inBlock: 0, "превет")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: { _ in throw ProofreadingError.missingKey }))
        await waitForAnswer(fixture)
        #expect(fixture.textView.proofreading.state == .failed("Нет ключа DeepSeek — добавьте его в Настройках"))
        fixture.textView.proofreading.start(with: nil)
        #expect(fixture.textView.proofreading.state == .failed(ProofreadingError.unavailable.localizedDescription))
    }

    @Test("Esc во время проверки закрывает окно и обрывает запрос")
    func cancelWhileChecking() async throws {
        let fixture = try await open([.paragraph("превет")])
        fixture.select(inBlock: 0, "превет")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: nil))
        #expect(fixture.textView.proofreading.state == .checking)
        fixture.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!fixture.textView.proofreading.isShown)
        #expect(fixture.texts == ["превет"])
    }

    @Test("Сдвинули выделение — окно закрывается")
    func selectionChangeCloses() async throws {
        let fixture = try await open([.paragraph("превет всем")])
        fixture.select(inBlock: 0, "превет")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: typos))
        await waitForAnswer(fixture)
        #expect(fixture.textView.proofreading.isShown)
        fixture.placeCaret(inBlock: 0, at: 2)
        #expect(!fixture.textView.proofreading.isShown)
    }

    @Test("Фокус ушёл из текста или страницу убрали из окна (другая вкладка, другая страница) — окно закрывается")
    func focusLossAndPageChangeClose() async throws {
        let fixture = try await open([.paragraph("превет всем")])
        fixture.select(inBlock: 0, "превет")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: typos))
        await waitForAnswer(fixture)
        #expect(fixture.textView.proofreading.isShown)
        fixture.window.makeFirstResponder(nil)
        #expect(!fixture.textView.proofreading.isShown)

        fixture.window.makeFirstResponder(fixture.textView)
        fixture.select(inBlock: 0, "превет")
        fixture.textView.proofreading.start(with: FakeProofreader(fix: nil))
        #expect(fixture.textView.proofreading.isShown)
        fixture.textView.removeFromSuperview()
        #expect(!fixture.textView.proofreading.isShown)
    }

    @Test("Код и формула не уходят на проверку")
    func skipsCode() {
        #expect(!ProofreadController.isProofreadable(.code))
        #expect(!ProofreadController.isProofreadable(.equation))
        #expect(ProofreadController.isProofreadable(.paragraph))
        #expect(ProofreadController.isProofreadable(.bulletItem))
    }
}
