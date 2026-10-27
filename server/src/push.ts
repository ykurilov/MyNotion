import type { Db } from './db.js';
import type { Devices } from './devices.js';
import type { Journal } from './journal.js';

/** Среда токена: `sandbox` — отладочная сборка из Xcode, `production` — TestFlight и App Store. */
export type PushEnvironment = 'sandbox' | 'production';
export const PUSH_ENVIRONMENTS: readonly PushEnvironment[] = ['sandbox', 'production'];

export interface PushResult {
  /** `unregistered` — Apple токен отверг: приложение удалили или токен чужой, больше на него не слать. */
  outcome: 'sent' | 'unregistered' | 'failed';
  status?: number;
  reason?: string;
}

export interface PushSender {
  send(deviceToken: string, environment: PushEnvironment): Promise<PushResult>;
}

/** Сроки схлопывания: iOS сама режет частые фоновые пуши, поэтому их мало и по делу. */
export interface PushTiming {
  /** Пачки серией (очередь Mac уходит по 20) — один пуш на всю серию. */
  debounceMs: number;
  /** Не чаще одного пуша устройству за этот срок; пачки внутри него — одним пушем в его конце. */
  minIntervalMs: number;
  /** Устройство считается на связи, пока идёт его запрос и ещё столько после: оно само заберёт пачки. */
  onlineGraceMs: number;
  /** Устройство было на связи, но пачки не подтвердило — проверить снова через этот срок. */
  recheckMs: number;
}

export const DEFAULT_PUSH_TIMING: PushTiming = {
  debounceMs: 3_000,
  minIntervalMs: 5 * 60_000,
  onlineGraceMs: 15_000,
  recheckMs: 45_000,
};

/**
 * Тихие пуши iPhone (specs/007-iphone-app, этап 1П): пришла пачка с другого устройства — разбудить спящие iPhone,
 * чтобы они забрали её сами. В пуше ничего из записей нет. Отправка не задерживает приём пачек: её сбой только в журнал.
 */
export interface Push {
  /** Токен APNs устройства; тот же токен у другого устройства (iPhone подключили заново) уходит от него. */
  register(deviceId: string, deviceToken: string, environment: PushEnvironment): void;
  /** Устройство удалено: токен стирается, ожидающие пуши отменяются. */
  forgetDevice(deviceId: string): void;
  /** Запрос устройства начался; вызвать возвращённую функцию, когда он кончится. */
  track(deviceId: string): () => void;
  /** Новая пачка (не повтор): разбудить остальных. */
  batchArrived(senderDeviceId: string): void;
  close(): void;
}

interface DeviceState {
  timer?: ReturnType<typeof setTimeout>;
  dueAt?: number;
  lastAttemptAt?: number;
  openRequests: number;
  lastSeenAt?: number;
}

interface TokenRow {
  device_id: string;
  token: string;
  environment: PushEnvironment;
}

const describeResult = (result: PushResult) =>
  [result.outcome, result.status, result.reason].filter((part) => part !== undefined).join(' ');

export function createPush(
  db: Db,
  options: {
    devices: Devices;
    journal: Journal;
    /** `null` — ключа Apple нет: токены копятся, пуши не уходят. */
    sender: PushSender | null;
    timing?: Partial<PushTiming>;
    log?: (message: string) => void;
  },
): Push {
  const { devices, journal, sender } = options;
  const timing = { ...DEFAULT_PUSH_TIMING, ...options.timing };
  const log = options.log ?? ((message: string) => console.log(message));
  const states = new Map<string, DeviceState>();

  const upsertToken = db.prepare(
    `INSERT INTO push_tokens (device_id, token, environment, updated_at) VALUES (?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET token = excluded.token, environment = excluded.environment, updated_at = excluded.updated_at`,
  );
  const deleteTokenElsewhere = db.prepare('DELETE FROM push_tokens WHERE token = ? AND device_id != ?');
  const deleteByDevice = db.prepare('DELETE FROM push_tokens WHERE device_id = ?');
  const deleteExact = db.prepare('DELETE FROM push_tokens WHERE device_id = ? AND token = ?');
  const tokenOf = db.prepare('SELECT device_id, token, environment FROM push_tokens WHERE device_id = ?');
  const allTokens = db.prepare('SELECT device_id, token, environment FROM push_tokens');

  const state = (deviceId: string) => {
    let found = states.get(deviceId);
    if (!found) states.set(deviceId, (found = { openRequests: 0 }));
    return found;
  };

  const isOnline = (deviceState: DeviceState | undefined, now: number) =>
    deviceState !== undefined &&
    (deviceState.openRequests > 0 || (deviceState.lastSeenAt !== undefined && now - deviceState.lastSeenAt < timing.onlineGraceMs));

  function cancel(deviceId: string): void {
    const deviceState = states.get(deviceId);
    if (deviceState?.timer) clearTimeout(deviceState.timer);
    if (deviceState) {
      deviceState.timer = undefined;
      deviceState.dueAt = undefined;
    }
  }

  /** Проверка не раньше `at`; уже назначенная раньше остаётся. */
  function schedule(deviceId: string, at: number): void {
    const deviceState = state(deviceId);
    if (deviceState.dueAt !== undefined && deviceState.dueAt <= at) return;
    if (deviceState.timer) clearTimeout(deviceState.timer);
    deviceState.dueAt = at;
    deviceState.timer = setTimeout(() => check(deviceId), Math.max(0, at - Date.now()));
    deviceState.timer.unref?.();
  }

  function check(deviceId: string): void {
    const deviceState = state(deviceId);
    deviceState.timer = undefined;
    deviceState.dueAt = undefined;
    try {
      const row = tokenOf.get(deviceId) as TokenRow | undefined;
      const device = devices.get(deviceId);
      if (!row || !device || !sender) return;
      // Всё до последней чужой пачки уже подтверждено: будить незачем.
      if (journal.latestSeqNotFrom(deviceId) <= device.lastAckSeq) return;
      const now = Date.now();
      if (isOnline(deviceState, now)) return schedule(deviceId, now + timing.recheckMs);
      const allowedAt = (deviceState.lastAttemptAt ?? -Infinity) + timing.minIntervalMs;
      if (now < allowedAt) return schedule(deviceId, allowedAt);
      deviceState.lastAttemptAt = now;
      void send(device.deviceName, row);
    } catch (error) {
      log(`Пуш устройству ${deviceId} не собран: ${error instanceof Error ? error.message : error}`);
    }
  }

  async function send(deviceName: string, row: TokenRow): Promise<void> {
    try {
      const result = await sender!.send(row.token, row.environment);
      if (result.outcome === 'unregistered') {
        deleteExact.run(row.device_id, row.token);
        log(`Пуш «${deviceName}»: Apple отверг токен (${describeResult(result)}) — токен забыт`);
      } else if (result.outcome === 'failed') {
        log(`Пуш «${deviceName}» не ушёл: ${describeResult(result)}`);
      }
    } catch (error) {
      log(`Пуш «${deviceName}» не ушёл: ${error instanceof Error ? error.message : error}`);
    }
  }

  return {
    register(deviceId, deviceToken, environment) {
      db.transaction(() => {
        deleteTokenElsewhere.run(deviceToken, deviceId);
        upsertToken.run(deviceId, deviceToken, environment, Date.now());
      })();
    },

    forgetDevice(deviceId) {
      cancel(deviceId);
      states.delete(deviceId);
      deleteByDevice.run(deviceId);
    },

    track(deviceId) {
      const deviceState = state(deviceId);
      deviceState.openRequests += 1;
      deviceState.lastSeenAt = Date.now();
      let open = true;
      return () => {
        if (!open) return;
        open = false;
        deviceState.openRequests -= 1;
        deviceState.lastSeenAt = Date.now();
      };
    },

    batchArrived(senderDeviceId) {
      if (!sender) return;
      try {
        const now = Date.now();
        for (const row of allTokens.all() as TokenRow[]) {
          if (row.device_id === senderDeviceId) continue;
          const lastAttemptAt = states.get(row.device_id)?.lastAttemptAt ?? -Infinity;
          schedule(row.device_id, Math.max(now + timing.debounceMs, lastAttemptAt + timing.minIntervalMs));
        }
      } catch (error) {
        log(`Пуши не назначены: ${error instanceof Error ? error.message : error}`);
      }
    },

    close() {
      for (const deviceId of states.keys()) cancel(deviceId);
    },
  };
}
