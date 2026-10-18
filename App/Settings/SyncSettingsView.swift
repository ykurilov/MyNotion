import NotesCore
import PageTree
import SwiftUI
import Sync
import VisualStyle

/// «Настройки → Синхронизация» (T080, research R9): включить на первом Mac токеном, подключить второй кодом,
/// «Добавить Mac» с кодом и предупреждением, список устройств, отключение.
struct SyncSettingsView: View {
    @Bindable var controller: SyncController
    @State private var token = ""
    @State private var codeText = ""
    @State private var confirmsDisable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Синхронизация")
                .font(.system(size: 18, weight: .semibold))
            Text("Одни и те же записи на всех ваших Mac. Записи шифруются здесь — сервер видит только зашифрованное.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.isEnabled { connected } else { disconnected }
            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(Color(nsColor: Palette.destructiveText))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-settings-error")
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .disabled(controller.isBusy)
        .task(id: controller.account?.deviceId) { if controller.isEnabled { await controller.refreshDevices() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-settings")
    }

    // MARK: Не подключён

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Сервер") {
                TextField("https://mynotion.kurilov.cloud", text: $controller.serverAddress)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sync-server-address")
            }
            LabeledContent("Имя этого Mac") {
                TextField("MacBook", text: $controller.deviceName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("sync-device-name")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Второй Mac: введите код с экрана уже подключённого Mac («Добавить Mac»).")
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("XXXX-XXXX-…", text: $codeText, axis: .vertical)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("sync-join-code")
                    Button("Подключить") { Task { await controller.join(codeText: codeText) } }
                        .disabled(codeText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("sync-join")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: { Text("Подключить к уже настроенным Mac").font(.system(size: 13, weight: .semibold)) }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Первый Mac: токен устройства, который выдала команда на сервере.")
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("Токен устройства", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("sync-first-token")
                    Button("Включить синхронизацию") { Task { await controller.connectFirstDevice(token: token) } }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("sync-enable-first")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            } label: { Text("Это первый Mac").font(.system(size: 13, weight: .semibold)) }
        }
    }

    // MARK: Подключён

    private var connected: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let badge = controller.badge {
                Label(badge.title, systemImage: badge.kind == .error ? "exclamationmark.icloud" : "checkmark.icloud")
                    .foregroundStyle(Color(nsColor: badge.kind == .error ? Palette.destructiveText : Palette.textPrimary))
                    .accessibilityIdentifier("sync-settings-status")
            }
            if let account = controller.account {
                Text("Этот Mac: \(account.deviceName) · \(account.serverURL.host() ?? account.serverURL.absoluteString)")
                    .foregroundStyle(.secondary)
            }
            joinCodeSection
            devicesSection
            Button("Выключить синхронизацию на этом Mac…") { confirmsDisable = true }
                .accessibilityIdentifier("sync-disable")
                .confirmationDialog("Выключить синхронизацию на этом Mac?", isPresented: $confirmsDisable) {
                    Button("Выключить", role: .destructive) { Task { await controller.disable() } }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Записи останутся на этом Mac. Правки перестанут уходить на другие Mac, пока вы снова не подключите этот.")
                }
        }
    }

    @ViewBuilder
    private var joinCodeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let code = controller.joinCode {
                    Text(code.text)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sync-join-code-text")
                    Label(JoinCode.warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color(nsColor: Palette.conflictLabelText))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sync-join-code-warning")
                    if let expiresAt = controller.joinCodeExpiresAt {
                        Text("Код одноразовый, действует до \(expiresAt.formatted(date: .omitted, time: .shortened)).")
                            .foregroundStyle(.secondary)
                    }
                    Button("Скрыть код") { controller.hideJoinCode() }
                } else {
                    Text("На новом Mac откройте «Настройки → Синхронизация» и введите код, который появится здесь.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Добавить Mac") { Task { await controller.makeJoinCode() } }
                        .accessibilityIdentifier("sync-add-mac")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: { Text("Добавить Mac").font(.system(size: 13, weight: .semibold)) }
    }

    private var devicesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if controller.devices.isEmpty {
                    Text("Список устройств появится, когда будет связь с сервером.").foregroundStyle(.secondary)
                }
                ForEach(controller.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.deviceName + (device.deviceId == controller.account?.deviceId ? " — этот Mac" : ""))
                            if let seen = device.lastSeenAt {
                                Text("На связи: \(seen.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if device.deviceId != controller.account?.deviceId {
                            Button("Отключить") { Task { await controller.disconnect(device) } }
                                .accessibilityIdentifier("sync-disconnect-device")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: { Text("Устройства").font(.system(size: 13, weight: .semibold)) }
    }
}
