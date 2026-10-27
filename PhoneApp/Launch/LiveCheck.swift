import Foundation
import NotesCore
import PhoneShell
import Sync

/// Живая проверка «Mac + iPhone в симуляторе» (scripts/imac/iphone-sync-live-check.zsh): подключиться кодом из файла,
/// дождаться страницы с Mac и дописать в неё абзац. Ход пишется строками в `--sync-log`.
@MainActor
enum LiveCheck {
    static func run(options: PhoneLaunchOptions, library: PhoneLibrary) async {
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
        do {
            try library.store.write { transaction in
                let last = try transaction.blocks(ofPage: page.id).filter { $0.containerId == nil }.last
                try transaction.insertBlock(Block(pageId: page.id, kind: .paragraph, text: InlineText(edit),
                                                  sortKey: FractionalSortKey.between(last?.sortKey, nil)))
            }
            library.browser.reload()
            sync.syncNow()
            log.write("edited")
        } catch {
            log.write("error: правка не записалась: \(error)")
        }
        let outbox = Outbox(store: library.store)
        let sent = await waitFor(seconds: 60) { (try? outbox.isEmpty()) == true ? true : nil }
        log.write(sent == nil ? "error: правка не ушла на сервер" : "sent")
        try? await Task.sleep(for: .seconds(3))
        log.write("done")
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
