import SwiftUI
import VisualStyle

/// «Подчёркивать ошибки»: красные подчёркивания, автоисправление и проверка грамматики macOS при вводе.
/// Переключается сразу во всех открытых окнах.
struct MistakeUnderliningToggle: View {
    @State private var isOn = MistakeUnderlining.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Подчёркивать ошибки", isOn: $isOn)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("underline-mistakes")
            Text("Красные подчёркивания и автоисправление при вводе. Без них ошибки правит «Исправить ошибки».")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
        .onChange(of: isOn) { _, isOn in MistakeUnderlining.isEnabled = isOn }
    }
}
