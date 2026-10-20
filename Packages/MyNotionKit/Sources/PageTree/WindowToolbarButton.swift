import SwiftUI
import VisualStyle

/// Кнопка верхней строки окна — шторка панели и «✎»: значок в квадрате `toolbarButtonSize`,
/// под мышью фон hoverBackground, как у кнопок Notion. Выключенная («‹ ›» вкладок, когда идти некуда) — серая.
public struct WindowToolbarButton: View {
    let symbol: String
    let symbolSize: CGFloat
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    public init(symbol: String, symbolSize: CGFloat, label: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.symbolSize = symbolSize
        self.label = label
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(Color(nsColor: isEnabled ? Palette.windowToolbarIcon : Palette.tabArrowDisabled))
                .frame(width: Metrics.Window.toolbarButtonSize, height: Metrics.Window.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(cornerRadius: Metrics.Window.toolbarButtonCornerRadius))
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
