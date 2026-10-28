import AIModels
import Foundation
import PageEditor
import SwiftUI
import Sync
import VisualStyle

/// Раздел настроек «ИИ-агент»: поле «Ключ OpenRouter» со скрытым вводом, «Сохранить», «Проверить», «Удалить».
/// DeepSeek агент берёт из раздела «Исправление ошибок» — ключ общий.
struct AIChatSettingsSection: View {
    let labelWidth: CGFloat
    /// Ключ уходит на другие устройства через синхронизацию; пришедший оттуда сразу виден здесь.
    let sync: SyncController
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
            Text("ИИ-агент").font(.system(size: 13, weight: .semibold))
            Text("Панель ИИ-агента справа в окне. DeepSeek идёт по ключу из раздела выше, GLM, Qwen и запасной путь DeepSeek — через OpenRouter.")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Ключ OpenRouter").frame(width: labelWidth, alignment: .leading)
                    SecureField(hasSavedKey ? "Ключ сохранён" : "sk-or-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("openrouter-key")
                }
                GridRow {
                    Color.clear.frame(width: labelWidth, height: 1)
                    HStack(spacing: 8) {
                        Button("Сохранить") { Task { await save() } }
                            .buttonStyle(ModalCardButtonStyle())
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                            .accessibilityIdentifier("openrouter-key-save")
                        Button("Проверить") { Task { await check() } }
                            .buttonStyle(ModalCardButtonStyle())
                            .disabled((key.isEmpty && !hasSavedKey) || isBusy)
                            .accessibilityIdentifier("openrouter-key-check")
                        if hasSavedKey {
                            Button("Удалить") { Task { await remove() } }
                                .buttonStyle(ModalCardButtonStyle())
                                .disabled(isBusy)
                                .accessibilityIdentifier("openrouter-key-remove")
                        }
                        if isBusy { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let status {
                switch status {
                case .ok(let text):
                    Text(text).foregroundStyle(Color(nsColor: Palette.notionText(.green)))
                        .accessibilityIdentifier("openrouter-key-status")
                case .failed(let text):
                    Text(text).foregroundStyle(Color(nsColor: Palette.destructiveText))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("openrouter-key-status")
                }
            }
        }
        .task(id: sync.serviceKeysRevision) { hasSavedKey = ((try? await AppAIChat.openRouterKeychain.key()) ?? nil) != nil }
    }

    private func save() async {
        await run {
            try await sync.saveServiceKey(key, for: ServiceKeyName.openRouter)
            key = ""
            hasSavedKey = true
            return "Ключ сохранён в Связке ключей"
        }
    }

    private func remove() async {
        await run {
            try await sync.saveServiceKey("", for: ServiceKeyName.openRouter)
            hasSavedKey = false
            return "Ключ удалён"
        }
    }

    /// Проверяет введённый ключ, а если поле пустое — сохранённый.
    private func check() async {
        await run {
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate = typed.isEmpty ? try await AppAIChat.openRouterKeychain.key() : typed else {
                throw ModelError.missingKey(.openRouter)
            }
            try await ModelKeyCheck.check(candidate, provider: .openRouter)
            return typed.isEmpty ? "Ключ работает" : "Ключ работает — нажмите «Сохранить»"
        }
    }

    private func run(_ action: () async throws -> String) async {
        isBusy = true
        defer { isBusy = false }
        do { status = .ok(try await action()) } catch let error as ModelError {
            status = .failed(error.message)
        } catch {
            status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
