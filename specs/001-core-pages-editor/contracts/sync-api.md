# Contract: Sync API

Сервер: `https://mynotion.kurilov.cloud` (индонезийский сервер). Только HTTPS.
Сервер хранит непрозрачные зашифрованные пачки и ничего не знает о страницах (R7, R9).

## Авторизация

`Authorization: Bearer <deviceToken>` во всех запросах, кроме `/health` и `/devices/join`.
Сервер хранит только sha256 токенов. Отключённое устройство получает `401`.

## Эндпоинты

### `GET /health`
`200 {"status":"ok"}`

### `POST /devices/invite`
Создаёт одноразовое приглашение для нового Mac.
- Ответ `201 {"inviteCode":"<строка>","expiresAt":"<ISO>"}`. Срок — 15 минут, одно использование.

### `POST /devices/join`
Тело: `{"inviteCode":"…","deviceName":"MacBook Юрия"}`
- `201 {"deviceId":"<uuid>","deviceToken":"<строка>","latestSnapshotSeq":<int|null>}`
- `410` — приглашение просрочено или уже использовано.

Ключ шифрования в запрос не входит: он передаётся только в коде подключения между Mac (R9).
Первое устройство создаётся командой на сервере (`mynotion-sync bootstrap`), токен передаётся через secret-handoff.

### `GET /devices`
`200 [{"deviceId","deviceName","lastSeenAt","lastAckSeq"}]`

### `DELETE /devices/{deviceId}`
Отключает устройство. `204`.

### `POST /changes`
Тело: `{"batchId":"<uuid>","ciphertext":"<base64>"}`. Размер до 4 МБ.
- `201 {"seq":<int>}` — номер в журнале.
- Повтор того же `batchId` — `200` с прежним `seq` (безопасный повтор после обрыва связи).

### `GET /changes?after=<seq>&wait=<0..25>`
- Есть пачки новее `after` — сразу `200 {"items":[{"seq","batchId","deviceId","ciphertext"}],"hasMore":bool}`, до 200 пачек.
- Нет — ждёт до `wait` секунд, затем `200 {"items":[],"hasMore":false}`.
- `410 {"snapshotSeq":<int>}` — журнал до `after` уже сжат: клиент сначала скачивает снимок.

### `POST /ack`
Тело: `{"seq":<int>}` — устройство применило всё до `seq`. Нужно для сжатия журнала.

### `PUT /snapshot`
Тело: `{"seq":<int>,"ciphertext":"<base64>"}`, до 200 МБ. Снимок всех записей на момент `seq`.
- `201`. Сервер удаляет пачки ≤ `seq`, как только все активные устройства подтвердили `seq` через `/ack`.

### `GET /snapshot`
`200 {"seq","ciphertext"}` или `404`.

## Содержимое пачки (после расшифровки, на Mac)

```json
{
  "formatVersion": 1,
  "deviceId": "…",
  "changes": [
    {"entity":"page","id":"…","field":"title","value":"…","hlc":"…"},
    {"entity":"block","id":"…","field":"text","value":{…},"hlc":"…","baseHlc":"…"}
  ]
}
```

- `formatVersion` растёт при несовместимом изменении. Mac с более старой версией не применяет пачку, а показывает «обновите MyNotion на этом Mac» — данные не теряются, пачка ждёт.
- Шифрование: ChaChaPoly (CryptoKit), nonce на пачку, `deviceId` и `batchId` входят в проверяемые данные.

## Ошибки

Единый вид: `{"error":"<код>","message":"<по-русски>"}`. Коды: `unauthorized`, `invite_expired`, `too_large`, `log_compacted`, `server_error`.
