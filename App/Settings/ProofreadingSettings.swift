import Foundation
import PageEditor
import Proofreading
import SwiftUI
import Sync
import VisualStyle

/// «Исправить ошибки» в приложении: ключ DeepSeek — в Связке ключей, читается не на главном потоке
/// и только при первом нажатии кнопки.
@MainActor
enum AppProofreading {
    static let keychain = ProofreadingKeychain()
    static let deepSeek = DeepSeekProofreader(apiKey: { try await keychain.key() })

    /// `fake` — UI-тесты и снимки: без сети и ключа, правит «превет» и «дила».
    static func install(fake: Bool) {
        PageTextView.proofreader = fake ? FakeProofreader() as any TextProofreader : deepSeek
    }

    private struct FakeProofreader: TextProofreader {
        func proofread(_ text: String) async throws -> String {
            try await Task.sleep(for: .milliseconds(500))
            return text.replacingOccurrences(of: "превет", with: "привет").replacingOccurrences(of: "дила", with: "дела")
        }
    }
}

/// Раздел настроек «Исправление ошибок»: поле «Ключ DeepSeek» со скрытым вводом, «Сохранить» и «Проверить».
struct ProofreadingSettingsSection: View {
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
            Text("Исправление ошибок").font(.system(size: 13, weight: .semibold))
            Text("Кнопка «Исправить ошибки» в меню выделенного текста отправляет текст в DeepSeek.")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Ключ DeepSeek").frame(width: labelWidth, alignment: .leading)
                    SecureField(hasSavedKey ? "Ключ сохранён" : "sk-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("proofreading-key")
                }
                GridRow {
                    Color.clear.frame(width: labelWidth, height: 1)
                    HStack(spacing: 8) {
                        Button("Сохранить") { Task { await save() } }
                            .buttonStyle(ModalCardButtonStyle())
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                            .accessibilityIdentifier("proofreading-key-save")
                        Button("Проверить") { Task { await check() } }
                            .buttonStyle(ModalCardButtonStyle())
                            .disabled((key.isEmpty && !hasSavedKey) || isBusy)
                            .accessibilityIdentifier("proofreading-key-check")
                        if hasSavedKey {
                            Button("Удалить") { Task { await remove() } }
                                .buttonStyle(ModalCardButtonStyle())
                                .disabled(isBusy)
                                .accessibilityIdentifier("proofreading-key-remove")
                        }
                        if isBusy { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let status {
                switch status {
                case .ok(let text):
                    Text(text).foregroundStyle(Color(nsColor: Palette.notionText(.green)))
                        .accessibilityIdentifier("proofreading-key-status")
                case .failed(let text):
                    Text(text).foregroundStyle(Color(nsColor: Palette.destructiveText))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("proofreading-key-status")
                }
            }
        }
        .task(id: sync.serviceKeysRevision) { hasSavedKey = ((try? await AppProofreading.keychain.key()) ?? nil) != nil }
    }

    private func save() async {
        await run {
            try await sync.saveServiceKey(key, for: ServiceKeyName.deepSeek)
            key = ""
            hasSavedKey = true
            return "Ключ сохранён в Связке ключей"
        }
    }

    private func remove() async {
        await run {
            try await sync.saveServiceKey("", for: ServiceKeyName.deepSeek)
            hasSavedKey = false
            return "Ключ удалён"
        }
    }

    /// Проверяет введённый ключ, а если поле пустое — сохранённый.
    private func check() async {
        await run {
            let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate = typed.isEmpty ? try await AppProofreading.keychain.key() : typed else {
                throw ProofreadingError.missingKey
            }
            try await AppProofreading.deepSeek.checkKey(candidate)
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
