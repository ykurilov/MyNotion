import AppKit
import SwiftUI
import VisualStyle

/// Окно поверх страницы (contracts/visual-style.md, «Окна поверх страницы»): сплошное затемнение на всё окно,
/// включая верхнюю полосу, и карточка шириной 520 посередине. Своё, а не системный лист: у листа затемнение
/// в светлой теме собрано из кусков, и по верхней полосе видны светлые щели.
struct ModalCardLayer<Card: View>: ViewModifier {
    static var width: CGFloat { 520 }

    let isPresented: Bool
    @ViewBuilder let card: () -> Card

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    Color(nsColor: Palette.modalBackdrop)
                        .ignoresSafeArea()
                        // Щелчки мимо карточки не доходят до страницы под затемнением.
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    card()
                        .font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: Palette.textPrimary))
                        .padding(20)
                        .frame(width: Self.width, alignment: .leading)
                        .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Palette.border)))
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                }
                .transition(.opacity)
                // Набор с клавиатуры не уходит в страницу под окном.
                .onAppear { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
    }
}

extension View {
    func modalCard<Card: View>(isPresented: Bool, @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(ModalCardLayer(isPresented: isPresented, card: card))
    }
}

/// Заголовок окна поверх страницы.
struct ModalCardTitle: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(.system(size: 16, weight: .semibold))
    }
}

/// Кнопка окна: главная — белый текст на синем, по Enter; остальные — рамка.
struct ModalCardButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: isPrimary ? .medium : .regular))
            .foregroundStyle(isPrimary ? Color.white : Color(nsColor: Palette.textPrimary))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(isPrimary ? Color(nsColor: Palette.primaryButtonFill) : Color(nsColor: Palette.popupMenuBackground),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isPrimary ? Color.clear : Color(nsColor: Palette.border)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
