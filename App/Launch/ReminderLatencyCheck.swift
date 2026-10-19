import AppKit
import Foundation
import NotesCore
import Reminders
import UserNotifications

/// `--reminder-latency-check <путь>`: живой замер SC-104 в виртуальном Mac. Ставит дату с напоминанием через
/// `lead` секунд, ждёт, когда система покажет уведомление, и пишет опоздание (момент показа − время напоминания)
/// в файл и в вывод. Не дождались за 3 минуты — «не пришло». Затем выход.
@MainActor
enum ReminderLatencyCheck {
    static let lead: TimeInterval = 65
    static let budget: TimeInterval = 60

    static func start(library: PagesLibrary, reportTo url: URL) {
        Task {
            let line: String
            do {
                line = try await measure(library: library)
            } catch {
                line = "Опоздание напоминания: не измерено (\(error.localizedDescription))"
            }
            print(line)
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func measure(library: PagesLibrary) async throws -> String {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return "Опоздание напоминания: разрешение не получено — \(error.localizedDescription) (\(error))"
            }
        }
        guard await SystemReminderNotificationCenter.requestAuthorization() else {
            return "Опоздание напоминания: уведомления не разрешены в этом Mac (статус \(status.rawValue))"
        }
        let fireAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + lead).rounded(.up))
        var calendar = Calendar.current
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        let date = DateMention(start: DateMention.startText(year: parts.year!, month: parts.month!, day: parts.day!,
                                                            hour: parts.hour, minute: parts.minute),
                               includesTime: true, timeZone: TimeZone.current.identifier,
                               reminder: DateMention.Reminder(fireAt: fireAt))
        try library.store.write { tx in
            let page = try tx.createPage(title: "Проверка напоминания")
            var block = try tx.blocks(ofPage: page.id)[0]
            block.text = InlineText("Напомнить \u{FFFC}", runs: [StyledRun(start: 10, length: 1, style: .date(date))])
            try tx.updateBlock(block)
        }
        library.reminders.start()
        let identifier = date.id.uuidString.lowercased()
        let deadline = fireAt.addingTimeInterval(180)
        while Date() < deadline {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            if let shown = delivered.first(where: { $0.request.identifier == identifier }) {
                let late = shown.date.timeIntervalSince(fireAt)
                let verdict = late <= budget ? "в бюджете ≤ \(Int(budget)) с" : "ВНЕ бюджета \(Int(budget)) с"
                return String(format: "Опоздание напоминания: %.1f с (%@)", late, verdict)
            }
            try await Task.sleep(for: .seconds(1))
        }
        return "Опоздание напоминания: не пришло за 3 минуты после срока"
    }
}
