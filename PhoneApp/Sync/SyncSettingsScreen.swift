import PhoneShell
import Sync
import SwiftUI

/// Настройки синхронизации: состояние, когда синхронизировано, устройства, выключить на этом iPhone.
struct SyncSettingsScreen: View {
    let sync: PhoneSyncController
    let connect: () -> Void
    let close: () -> Void
    @State private var confirmsDisable = false

    var body: some View {
        Form {
            if sync.isEnabled { connectedSections } else { notConnectedSection }
        }
        .navigationTitle("Синхронизация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Готово", action: close) }
        }
        .task(id: sync.isEnabled) { if sync.isEnabled { await sync.refreshDevices() } }
        .refreshable {
            sync.syncNow()
            await sync.refreshDevices()
        }
        .accessibilityIdentifier("sync-settings")
    }

    @ViewBuilder
    private var connectedSections: some View {
        if let badge = sync.badge {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(badge.kind == .error ? PhoneTheme.destructive : PhoneTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(badge.title).font(.headline)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(badge.kind == .error ? badge.detail : badge.lastSyncedText(now: context.date))
                                .font(.subheadline)
                                .foregroundStyle(badge.kind == .error ? PhoneTheme.destructive : PhoneTheme.textSecondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                Button("Синхронизировать сейчас", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }
            }
        }
        Section("Устройства") {
            ForEach(sync.devices) { device in
                VStack(alignment: .leading, spacing: 2) {
                    Text(sync.isThisDevice(device) ? "\(device.deviceName) — этот iPhone" : device.deviceName)
                    if let seen = device.lastSeenAt {
                        Text("Был на связи: \(seen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(PhoneTheme.textSecondary)
                    }
                }
            }
            if sync.devices.isEmpty {
                Text("Список загружается…").foregroundStyle(PhoneTheme.textSecondary)
            }
        }
        Section {
            Button("Выключить на этом iPhone", role: .destructive) { confirmsDisable = true }
                .disabled(sync.isBusy)
                .confirmationDialog("Выключить синхронизацию на этом iPhone?", isPresented: $confirmsDisable,
                                    titleVisibility: .visible) {
                    Button("Выключить", role: .destructive) { Task { await sync.disable() } }
                } message: {
                    Text("Записи останутся на iPhone, но новые правки с Mac сюда больше не придут.")
                }
        } footer: {
            if let error = sync.errorMessage { Text(error).foregroundStyle(PhoneTheme.destructive) }
        }
    }

    private var notConnectedSection: some View {
        Section {
            Button("Подключить кодом с Mac", systemImage: "macbook.and.iphone", action: connect)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = sync.errorMessage { Text(error).foregroundStyle(PhoneTheme.destructive) }
                Text("Пока iPhone не подключён, записи хранятся только на нём.")
            }
        }
    }
}
