import AIModels
import SwiftUI

/// Поле ввода внизу панели: текст, выбор модели и уровня рассуждений, «Отправить» или «Стоп».
struct AIChatComposer: View {
    @Bindable var controller: AIChatController
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Спросите или попросите что-нибудь…", text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AIChatStyle.bodyFont)
                .foregroundStyle(AIChatStyle.text)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit { controller.send() }
                .accessibilityIdentifier("ai-chat-input")
            HStack(spacing: 4) {
                chip(controller.model.title, popup: .models, identifier: "ai-chat-model")
                chip(controller.model.title(for: controller.level), popup: .levels, identifier: "ai-chat-level")
                Spacer(minLength: 8)
                sendOrStop
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(AIChatStyle.background))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isFocused ? AIChatStyle.accent.opacity(0.5) : AIChatStyle.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
        .overlay(alignment: .topLeading) {
            Group {
                switch controller.popup {
                case .models: modelList
                case .levels: levelList
                case .pastChats, nil: EmptyView()
                }
            }
            .alignmentGuide(.top) { $0[.bottom] + 6 }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onAppear { isFocused = true }
        .onChange(of: controller.isOpen) { _, isOpen in if isOpen { isFocused = true } }
    }

    private func chip(_ title: String, popup: AIChatController.Popup, identifier: String) -> some View {
        Button { controller.toggle(popup) } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(AIChatStyle.smallFont)
            .foregroundStyle(AIChatStyle.secondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(controller.popup == popup ? AIChatStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var sendOrStop: some View {
        if controller.isRunning {
            Button { controller.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(AIChatStyle.background)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AIChatStyle.text))
            }
            .buttonStyle(.plain)
            .help("Стоп")
            .accessibilityIdentifier("ai-chat-stop")
        } else {
            let canSend = !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { controller.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? AIChatStyle.accent : AIChatStyle.placeholder.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Отправить")
            .accessibilityIdentifier("ai-chat-send")
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            AIChatPopupHeader(title: "Модель")
            ForEach(ModelCatalog.all) { model in
                AIChatPopupRow(isSelected: model == controller.model, action: { controller.select(model) }) {
                    Text(model.title)
                }
            }
        }
        .frame(width: 240)
        .aiChatPopupCard()
        .accessibilityIdentifier("ai-chat-model-list")
    }

    private var levelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            AIChatPopupHeader(title: "Рассуждения")
            ForEach(controller.model.options, id: \.level) { option in
                AIChatPopupRow(isSelected: option.level == controller.level, action: { controller.select(level: option.level) }) {
                    Text(option.title)
                }
            }
        }
        .frame(width: 220)
        .aiChatPopupCard()
        .accessibilityIdentifier("ai-chat-level-list")
    }
}
