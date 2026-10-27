import PhoneShell
import SwiftUI

/// Подключение iPhone кодом с Mac: подсказка, где взять код, поле для кода с кнопкой «Вставить» и понятная ошибка.
struct ConnectScreen: View {
    @Bindable var sync: PhoneSyncController
    let close: () -> Void
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        Form {
            Section {
                ConnectStep(number: 1, text: "На Mac откройте MyNotion → Настройки → Синхронизация.")
                ConnectStep(number: 2, text: "Нажмите «Добавить Mac или iPhone» и скопируйте код.")
                ConnectStep(number: 3, text: "Вставьте код сюда — он действует 10 минут.")
            }
            Section {
                TextField("Код с Mac", text: $code, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($codeFocused)
                    .accessibilityIdentifier("join-code")
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    code = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("paste-code")
            } header: {
                Text("Код подключения")
            } footer: {
                if let error = sync.errorMessage {
                    Text(error)
                        .foregroundStyle(PhoneTheme.destructive)
                        .accessibilityIdentifier("connect-error")
                }
            }
            Section("Имя этого iPhone") {
                TextField("iPhone", text: $sync.deviceName)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("device-name")
            }
            Section {
                DisclosureGroup("Другой сервер") {
                    TextField("Адрес сервера", text: $sync.serverAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                }
                .foregroundStyle(PhoneTheme.textSecondary)
            }
        }
        .navigationTitle("Подключить к Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена", action: close)
            }
            ToolbarItem(placement: .confirmationAction) {
                if sync.isBusy {
                    ProgressView()
                } else {
                    Button("Подключить", action: connect)
                        .fontWeight(.semibold)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("connect")
                }
            }
        }
        .interactiveDismissDisabled(sync.isBusy)
        .onAppear { sync.errorMessage = nil }
    }

    private func connect() {
        codeFocused = false
        Task {
            await sync.join(codeText: code)
            if sync.isEnabled { close() }
        }
    }
}

private struct ConnectStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(PhoneTheme.accent, in: Circle())
            Text(text)
                .foregroundStyle(PhoneTheme.textPrimary)
        }
    }
}
