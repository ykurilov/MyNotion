import Foundation
import NotionAPI
import SwiftUI
import VisualStyle

/// Картинки вставки из Notion: ключ интеграции — в Связке ключей, читается не на главном потоке
/// и только при первой вставке картинки.
@MainActor
enum AppNotion {
    static let keychain = NotionKeychain()
    static let client = NotionClient(key: { try await keychain.key() })
}

/// Раздел настроек «Картинки из Notion»: поле «Ключ Notion» со скрытым вводом, «Сохранить» и «Проверить».
struct NotionSettingsSection: View {
    let labelWidth: CGFloat
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var status: Status?
    @State private var isBusy = false

    private enum Status: Equatable {
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Картинки из Notion").font(.system(size: 13, weight: .semibold))
            Text("""
                Картинки при вставке из Notion скачиваются по ключу интеграции. Создайте интеграцию на \
                notion.so/profile/integrations, вставьте сюда её ключ и подключите её к нужным страницам: \
                в Notion «•••» → «Подключения».
                """)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Ключ Notion").frame(width: labelWidth, alignment: .leading)
                    SecureField(hasSavedKey ? "Ключ сохранён" : "ntn_…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("notion-key")
                }
                GridRow {
                    Color.clear.frame(width: labelWidth, height: 1)
                    HStack(spacing: 8) {
                        Button("Сохранить") { Task { await save() } }
                            .buttonStyle(ModalCardButtonStyle())
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                            .accessibilityIdentifier("notion-key-save")
                        Button("Проверить") { Task { await check() } }
                            .buttonStyle(ModalCardButtonStyle())
                            .disabled((key.isEmpty && !hasSavedKey) || isBusy)
                            .accessibilityIdentifier("notion-key-check")
                        if hasSavedKey {
                            Button("Удалить") { Task { await remove() } }
                                .buttonStyle(ModalCardButtonStyle())
                                .disabled(isBusy)
                                .accessibilityIdentifier("notion-key-remove")
                        }
                        if isBusy { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let status {
                switch status {
                case .ok(let text):
                    Text(text).foregroundStyle(Color(nsColor: Palette.notionText(.green)))
                        .accessibilityIdentifier("notion-key-status")
                case .failed(let text):
                    Text(text).foregroundStyle(Color(nsColor: Palette.destructiveText))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("notion-key-status")
                }
            }
        }
        .task { hasSavedKey = ((try? await AppNotion.keychain.key()) ?? nil) != nil }
    }

    private func save() async {
        await run {
            try await AppNotion.keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
            key = ""
            hasSavedKey = true
            return "Ключ сохранён в Связке ключей"
        }
    }

    private func remove() async {
        await run {
            try await AppNotion.keychain.save("")
            hasSavedKey = false
            return "Ключ удалён"
        }
    }

    /// Проверяет введённый ключ, а если поле пустое — сохранённый.
    private func check() async {
        await run {
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate = typed.isEmpty ? try await AppNotion.keychain.key() : typed else {
                throw NotionAPIError.missingKey
            }
            try await AppNotion.client.checkKey(candidate)
            return typed.isEmpty ? "Ключ работает" : "Ключ работает — нажмите «Сохранить»"
        }
    }

    private func run(_ action: () async throws -> String) async {
        isBusy = true
        defer { isBusy = false }
        do { status = .ok(try await action()) } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
