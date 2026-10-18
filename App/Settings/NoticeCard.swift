import SwiftUI
import VisualStyle

/// Карточка хода внизу окна (contracts/visual-style.md, «Карточки хода»): перенос из Notion, выгрузка в Markdown.
/// Одна манера у всех: «Что сделано: N из M», полоска при известном числе, крутилка — пока числа нет,
/// справа кнопка действия и «Закрыть».
struct NoticeCard<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) { content() }
            .font(.system(size: 14))
            .foregroundStyle(Color(nsColor: Palette.textPrimary))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: Palette.border)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.bottom, 20)
            .transition(.opacity)
            // Идентификатор на контейнере иначе прячет вложенные текст и кнопки от VoiceOver и UI-тестов.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

/// Ход: полоска, если известно «из скольких», иначе крутилка; рядом фраза в одну строку.
struct NoticeProgress: View {
    let done: Int
    let total: Int
    let text: String

    var body: some View {
        if total > 0 {
            // Своя полоска: системная на macOS не красится и почти сливается с карточкой.
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: Palette.border))
                Capsule().fill(Color(nsColor: Palette.primaryButtonFill))
                    .frame(width: max(6, 140 * CGFloat(min(done, total)) / CGFloat(total)))
            }
            .frame(width: 140, height: 6)
            .accessibilityElement()
            .accessibilityLabel(text)
            .accessibilityValue("\(Int(100 * Double(min(done, total)) / Double(total))) %")
        } else {
            ProgressView().controlSize(.small)
        }
        Text(verbatim: text).monospacedDigit().lineLimit(1).fixedSize()
    }
}

/// Число по-русски: «1 000», «147 400».
func number(_ value: Int) -> String {
    value.formatted(.number.locale(Locale(identifier: "ru_RU")))
}
