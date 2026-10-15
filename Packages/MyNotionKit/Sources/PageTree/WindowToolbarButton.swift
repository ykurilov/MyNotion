import SwiftUI
import VisualStyle

/// Кнопка верхней строки окна — шторка панели и «✎»: значок в квадрате `toolbarButtonSize`,
/// под мышью фон hoverBackground, как у кнопок Notion.
public struct WindowToolbarButton: View {
    let symbol: String
    let symbolSize: CGFloat
    let label: String
    let action: () -> Void

    public init(symbol: String, symbolSize: CGFloat, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.symbolSize = symbolSize
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(Color(nsColor: Palette.windowToolbarIcon))
                .frame(width: Metrics.Window.toolbarButtonSize, height: Metrics.Window.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(cornerRadius: Metrics.Window.toolbarButtonCornerRadius))
        .help(label)
        .accessibilityLabel(label)
    }
}
