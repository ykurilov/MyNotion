import { describe, expect, it } from 'vitest';
import { readConfig } from '../src/config.js';

describe('настройки пушей', () => {
  it('без ключа APNs пуши выключены', () => {
    expect(readConfig({ APNS_KEY_FILE: '', APNS_KEY_ID: '' }).apns).toBeNull();
  });

  it('пустые необязательные переменные из docker-compose дают значения по умолчанию', () => {
    const config = readConfig({
      APNS_KEY_FILE: '/data/apns/AuthKey_K.p8',
      APNS_KEY_ID: ' K ',
      APNS_TEAM_ID: '',
      APNS_TOPIC: ' ',
      PUSH_MIN_INTERVAL_SECONDS: '',
    });
    expect(config.apns).toEqual({
      keyFile: '/data/apns/AuthKey_K.p8',
      keyId: 'K',
      teamId: 'DC5QSJ54MB',
      topic: 'cloud.kurilov.mynotion.ios',
      origin: undefined,
    });
    expect(config.pushMinIntervalMs).toBe(5 * 60_000);
  });

  it('заданные значения берутся', () => {
    const config = readConfig({
      APNS_KEY_FILE: '/k.p8',
      APNS_KEY_ID: 'K',
      APNS_TEAM_ID: 'TEAM',
      APNS_TOPIC: 'app.topic',
      PUSH_MIN_INTERVAL_SECONDS: '60',
    });
    expect(config.apns).toMatchObject({ teamId: 'TEAM', topic: 'app.topic' });
    expect(config.pushMinIntervalMs).toBe(60_000);
  });
});
