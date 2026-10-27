import Foundation
import NotesCore
import PhoneShell
import Sync
import UIKit

/// Живая проверка «Mac + iPhone в симуляторе» (scripts/imac/iphone-sync-live-check.zsh): подключиться кодом из файла,
/// дождаться страницы с Mac, открыть её и напечатать текст в редакторе, затем дождаться на открытой странице правки с Mac.
/// Ход пишется строками в `--sync-log`.
@MainActor
enum LiveCheck {
    static func run(options: PhoneLaunchOptions, library: PhoneLibrary, openPage: (UUID) -> Void) async {
        guard options.joinCodeFile != nil || options.liveCheckPageTitle != nil || options.syncLog != nil else { return }
        let log = LiveCheckLog(url: options.syncLog)
        let sync = library.sync
        let statusLog = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                let line = sync.badge.map { "status: \($0.title) — \($0.detail)" } ?? "status: выключена"
                if line != last { log.write(line); last = line }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { statusLog.cancel() }

        if let file = options.joinCodeFile, !sync.isEnabled {
            guard let code = await waitFor(seconds: 120, { try? String(contentsOf: file, encoding: .utf8) }) else {
                return log.write("error: нет файла с кодом \(file.path)")
            }
            await sync.join(codeText: code)
            guard sync.isEnabled else { return log.write("error: не подключился: \(sync.errorMessage ?? "?")") }
            log.write("joined")
        }

        guard let title = options.liveCheckPageTitle else { return }
        let page = await waitFor(seconds: 120) { () -> Page? in
            library.browser.reload()
            return (try? library.store.pageOutline())?.first { $0.title == title && library.browser.isAvailable($0.id) }
        }
        guard let page else { return log.write("error: страница «\(title)» не пришла") }
        log.write("page-arrived: \(page.id.uuidString)")

        guard let edit = options.liveCheckEdit else { return }
        // Пауза — снимок дерева со страницей, пришедшей с Mac.
        try? await Task.sleep(for: .seconds(3))
        openPage(page.id)
        // Как пальцем: курсор в конец последнего блока на экране и набор с клавиатуры.
        guard let field = await waitFor(seconds: 20, { lastEditableField() }) else {
            return log.write("error: редактор страницы не показал блоков")
        }
        field.becomeFirstResponder()
        field.selectedRange = NSRange(location: field.text.utf16.count, length: 0)
        field.insertText(" \(edit)")
        library.openDocuments.saveAll()
        sync.syncNow()
        log.write("edited")
        let outbox = Outbox(store: library.store)
        let sent = await waitFor(seconds: 60) { (try? outbox.isEmpty()) == true ? true : nil }
        log.write(sent == nil ? "error: правка не ушла на сервер" : "sent")

        guard let macEdit = options.liveCheckMacEdit else { return log.write("done") }
        let shown = await waitFor(seconds: 90) { visibleFields().contains { $0.text.contains(macEdit) } ? true : nil }
        log.write(shown == nil ? "error: правка с Mac не появилась на открытой странице" : "mac-edit-visible")
        log.write("done")
    }

    private static func visibleFields() -> [UITextView] {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.flatMap { textViews(in: $0) }.filter { $0.isEditable && $0.window != nil }
    }

    private static func lastEditableField() -> UITextView? {
        visibleFields().filter { !$0.text.isEmpty }.max { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    /// Ждать, пока `value` не вернёт значение; проверка раз в полсекунды.
    private static func waitFor<T>(seconds: Double, _ value: @MainActor () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let result = value() { return result }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}

private struct LiveCheckLog {
    let url: URL?

    func write(_ line: String) {
        guard let url else { return }
        let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
