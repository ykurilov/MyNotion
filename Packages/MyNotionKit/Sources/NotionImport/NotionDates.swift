import Foundation
import NotesCore

/// Даты в тексте выгрузки (contracts/markdown-and-notion.md): Notion пишет «@October 20, 2026» и «@October 20, 2026 9:30 PM»,
/// наша выгрузка — «<time datetime=… data-timezone=… data-remind=…>». Без пояса дата получает пояс этого Mac.
enum NotionDates {
    enum Piece: Equatable {
        case text(String)
        case date(DateMention)
    }

    private static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                        "October", "November", "December"]
    private static let russianMonths = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября",
                                        "октября", "ноября", "декабря"]

    private static let english = try! NSRegularExpression(pattern:
        #"@(\#(englishMonths.joined(separator: "|"))) (\d{1,2}), (\d{4})(?: (\d{1,2}):(\d{2})(?: ?(AM|PM))?)?"#)
    private static let russian = try! NSRegularExpression(pattern:
        #"@(\d{1,2}) (\#(russianMonths.joined(separator: "|"))) (\d{4})(?:,? (\d{1,2}):(\d{2}))?"#)

    /// Текст, разрезанный на куски и даты.
    static func split(_ text: String, timeZone: TimeZone = .current) -> [Piece] {
        guard text.contains("@") else { return [.text(text)] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, DateMention)] = []
        for match in english.matches(in: text, range: whole) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            guard let monthName = group(1), let month = englishMonths.firstIndex(of: monthName), let day = group(2).flatMap(Int.init),
                  let year = group(3).flatMap(Int.init) else { continue }
            var hour = group(4).flatMap(Int.init)
            if let hour12 = hour, let meridiem = group(6) {
                hour = hour12 % 12 + (meridiem == "PM" ? 12 : 0)
            }
            if let mention = mention(year: year, month: month + 1, day: day, hour: hour, minute: group(5).flatMap(Int.init), timeZone: timeZone) {
                found.append((match.range, mention))
            }
        }
        for match in russian.matches(in: text, range: whole) {
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            guard let day = group(1).flatMap(Int.init), let monthName = group(2), let month = russianMonths.firstIndex(of: monthName),
                  let year = group(3).flatMap(Int.init) else { continue }
            if let mention = mention(year: year, month: month + 1, day: day, hour: group(4).flatMap(Int.init),
                                     minute: group(5).flatMap(Int.init), timeZone: timeZone) {
                found.append((match.range, mention))
            }
        }
        guard !found.isEmpty else { return [.text(text)] }
        var pieces: [Piece] = []
        var location = 0
        for (range, mention) in found.sorted(by: { $0.0.location < $1.0.location }) where range.location >= location {
            if range.location > location { pieces.append(.text(ns.substring(with: NSRange(location: location, length: range.location - location)))) }
            pieces.append(.date(mention))
            location = NSMaxRange(range)
        }
        if location < ns.length { pieces.append(.text(ns.substring(from: location))) }
        return pieces
    }

    private static func mention(year: Int, month: Int, day: Int, hour: Int?, minute: Int?, timeZone: TimeZone) -> DateMention? {
        guard (1...31).contains(day), hour.map({ (0...23).contains($0) }) ?? true, minute.map({ (0...59).contains($0) }) ?? true else {
            return nil
        }
        return DateMention(start: DateMention.startText(year: year, month: month, day: day, hour: hour, minute: hour == nil ? nil : minute),
                           includesTime: hour != nil, timeZone: timeZone.identifier)
    }

    /// Наша `<time datetime="2026-10-20T09:00+08:00" data-timezone="Asia/Makassar" data-remind="…">…</time>`.
    static func date(fromTimeTag tag: String) -> DateMention? {
        func attribute(_ name: String) -> String? {
            guard let range = tag.range(of: name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
            return String(tag[range].dropFirst(name.count + 2).dropLast())
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        guard let datetime = attribute("datetime") else { return nil }
        let day = String(datetime.prefix(10))
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let rest = datetime.dropFirst(10)
        var start = day
        var includesTime = false
        var zone = attribute("data-timezone").flatMap(TimeZone.init(identifier:))
        if rest.hasPrefix("T") {
            let time = String(rest.dropFirst().prefix(5))
            guard time.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
            start += "T" + time
            includesTime = true
            if zone == nil, let offset = offsetSeconds(String(rest.dropFirst(6))) { zone = TimeZone(secondsFromGMT: offset) }
        }
        let reminder = attribute("data-remind").flatMap { try? Date($0, strategy: .iso8601) }.map(DateMention.Reminder.init(fireAt:))
        return DateMention(start: start, includesTime: includesTime, timeZone: (zone ?? .current).identifier, reminder: reminder)
    }

    /// `+08:00` → 28 800.
    private static func offsetSeconds(_ text: String) -> Int? {
        if text == "Z" { return 0 }
        guard text.count == 6, let sign = text.first, sign == "+" || sign == "-",
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)) else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}
