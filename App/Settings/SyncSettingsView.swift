import AppKit
import NotesCore
import PageTree
import SwiftUI
import Sync
import VisualStyle

/// «Настройки → Синхронизация» (T080, research R9; проверка интерфейса, раунд 4, № 2, 7, 8, 9): простыми словами,
/// без слов разработчика. Глаголы договорены: «Подключить Mac» — этот Mac к остальным, «Добавить Mac» — показать код
/// для нового, «Убрать» — чужой Mac из списка, «Выключить на этом Mac» — остановить у себя.
struct SyncSettingsView: View {
    @Bindable var controller: SyncController
    @State private var codeText = ""
    @State private var confirmsDisable = false

    /// Ширина окон поверх страницы (contracts/visual-style.md, «Окна поверх страницы»).
    static let width: CGFloat = 520
    /// Колонка подписей у полей: поля начинаются на одной линии.
    private static let labelWidth: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Одни записи на всех ваших Mac")
                .font(.system(size: 18, weight: .semibold))
            Text("Правки с одного Mac сами появляются на других. Прочитать записи могут только ваши Mac.")
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
        .frame(width: Self.width, alignment: .leading)
        .disabled(controller.isBusy)
        .focusEffectDisabled()
        .task(id: controller.account?.deviceId) { if controller.isEnabled { await controller.refreshDevices() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-settings")
    }

    // MARK: Этот Mac ещё не подключён

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Имя этого Mac").frame(width: Self.labelWidth, alignment: .leading)
                    TextField("MacBook", text: $controller.deviceName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("sync-device-name")
                }
                GridRow {
                    Text("Код с другого Mac").frame(width: Self.labelWidth, alignment: .leading)
                    TextField("XXXX-XXXX-…", text: $codeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityIdentifier("sync-join-code")
                }
                GridRow {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("На Mac, где записи уже есть, откройте эти настройки и нажмите «Добавить Mac» — появится код.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Подключить Mac") { Task { await controller.join(codeText: codeText) } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(codeText.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("sync-join")
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Это ваш первый Mac?").font(.system(size: 13, weight: .semibold))
                Text("Тогда кода ещё нет. Нужен файл-ключ «mynotion-sync-device.env» — его выдаёт тот, кто настраивал MyNotion.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Выбрать файл-ключ…") { chooseKeyFile() }
                    .accessibilityIdentifier("sync-enable-first")
            }
        }
    }

    /// Окно выбора файла-ключа: сразу в папке, куда его кладут при установке; скрытые папки видны.
    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Подключить Mac"
        panel.message = "Выберите файл-ключ «mynotion-sync-device.env»"
        let secrets = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/secrets", isDirectory: true)
        if FileManager.default.fileExists(atPath: secrets.path) { panel.directoryURL = secrets }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task { await controller.connectFirstDevice(keyFile: file) }
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
                Text("Этот Mac называется «\(account.deviceName)».")
                    .foregroundStyle(.secondary)
            }
            joinCodeSection
            devicesSection
            Button("Выключить на этом Mac…") { confirmsDisable = true }
                .accessibilityIdentifier("sync-disable")
                .confirmationDialog("Выключить на этом Mac?", isPresented: $confirmsDisable) {
                    Button("Выключить", role: .destructive) { Task { await controller.disable() } }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text("Записи останутся на этом Mac. Новые правки перестанут уходить на другие Mac, пока вы снова не подключите этот.")
                }
        }
    }

    @ViewBuilder
    private var joinCodeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let code = controller.joinCode {
                    Text("Введите этот код на новом Mac в «Настройки → Код с другого Mac»:")
                        .fixedSize(horizontal: false, vertical: true)
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
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(JoinCode.lifetimeText(until: expiresAt, now: context.date))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("sync-join-code-lifetime")
                        }
                    }
                    Button("Скрыть код") { controller.hideJoinCode() }
                } else {
                    Text("Чтобы подключить ещё один Mac, нажмите кнопку — здесь появится код. Его нужно ввести на новом Mac.")
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
                    Text("Список появится, когда будет интернет.").foregroundStyle(.secondary)
                }
                ForEach(controller.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.deviceName + (device.deviceId == controller.account?.deviceId ? " — этот Mac" : ""))
                            if let seen = device.lastSeenAt {
                                Text("Был на связи: \(seen.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if device.deviceId != controller.account?.deviceId {
                            Button("Убрать") { Task { await controller.disconnect(device) } }
                                .help("Этот Mac перестанет получать ваши записи — например, если он потерян или продан")
                                .accessibilityIdentifier("sync-disconnect-device")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: { Text("Ваши Mac").font(.system(size: 13, weight: .semibold)) }
    }
}
