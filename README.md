# VPN Deploy

Автоматическое развёртывание двухсерверного VPN (VLESS + Reality) за одну команду. Сделано с Opus 4.6

## Архитектура

```
Клиент (AmneziaVPN)
  → Russia:443 (Xray: расшифровка + domain routing)
    → [YouTube и др.]  → ByeDPI (SOCKS5) → Интернет (рос. IP, DPI bypass)
    → [AI-сервисы]     → Latvia:8443 (Xray) → WARP → Интернет (IP Cloudflare)
    → [всё остальное]  → Latvia:8443 (Xray) → Интернет (IP Латвии)
```

**Russia** — Xray VPN-роутер + ByeDPI. Принимает клиентов, маршрутизирует по доменам.
**Latvia** — Xray exit-нода + WARP. Расходный материал — легко заменить на новый IP.

## Файлы

| Файл | Где запускать | Назначение |
|---|---|---|
| `deploy.sh` | На Russia | Поднимает exit-ноду (Latvia), обновляет Russia, выдаёт ссылки |
| `setup-relay.sh` | На новом relay | Одноразовая настройка relay-сервера с нуля (legacy) |
| `config.env` | — | Настройки: пользователи, SNI, bypass-домены, WARP-домены |
| `links-*.txt` | — | Сгенерированные VLESS-ссылки (создаются после деплоя) |

---

## Быстрый старт

### Новый exit-сервер (Russia уже настроена)

```bash
ssh root@<RUSSIA_IP>
/opt/vpn-deploy/deploy.sh <EXIT_IP> '<ROOT_PASSWORD>'
```

Скрипт сделает всё сам: установит Xray, сгенерирует ключи, настроит systemd/logrotate/DNS/WARP, обновит Russia, прогонит тест и выдаст готовые VLESS-ссылки.

---

## Управление пользователями

### Посмотреть текущих

```bash
ssh root@<RUSSIA_IP>
python3 -c "
import json
with open('/usr/local/etc/xray/config.json') as f:
    c = json.load(f)
for i, cl in enumerate(c['inbounds'][0]['settings']['clients']):
    flow = cl.get('flow', 'нет (service)')
    print(f'{i:2d}  {cl[\"id\"]}  flow={flow}')
"
```

### Добавить пользователя

1. Сгенерировать UUID:
```bash
/usr/local/bin/xray uuid
```

2. Добавить на **Russia** в `/usr/local/etc/xray/config.json` → `inbounds[0].settings.clients`:
```json
{"flow": "xtls-rprx-vision", "id": "НОВЫЙ-UUID"}
```

3. Добавить тот же UUID на **Latvia** (тоже с flow):
```bash
ssh root@<LATVIA_IP>
# Отредактировать /usr/local/etc/xray/config.json — тот же clients[]
```

4. Перезапустить оба:
```bash
systemctl restart xray                              # на Russia
ssh root@<LATVIA_IP> 'systemctl restart xray'        # на Latvia
```

5. Отправить пользователю ссылку:
```
vless://НОВЫЙ-UUID@<RUSSIA_IP>:443?encryption=none&flow=xtls-rprx-vision&type=tcp&security=reality&sni=www.github.com&fp=chrome&pbk=<RUSSIA_PUBLIC_KEY>&sid=<SHORT_ID>#Имя
```
Значения `pbk` и `sid` — в текущих ссылках или в `dev/VPN.md`.

### Удалить пользователя

1. Убрать его UUID из конфигов **обоих** серверов
2. `systemctl restart xray` на обоих

---

## Редактирование списков доменов

### ByeDPI bypass (YouTube и др. → рос. IP)

Домены, которые идут через ByeDPI на Russia. Редактируются на **Russia**:

```bash
ssh root@<RUSSIA_IP>
nano /usr/local/etc/xray/config.json
# → routing → rules → найти outboundTag: "bypass" → domain: [...]
systemctl restart xray
```

Формат: `"domain:example.com"` — совпадает с example.com и всеми поддоменами.

Для синхронизации — обновить `BYPASS_DOMAINS` в локальном `config.env`.

### WARP (AI-сервисы → IP Cloudflare)

Домены, которые идут через WARP на Latvia. Редактируются на **Latvia**:

```bash
ssh root@<RUSSIA_IP>
ssh root@<LATVIA_IP>
nano /usr/local/etc/xray/config.json
# → routing → rules → найти outboundTag: "warp" → domain: [...]
systemctl restart xray
```

Для синхронизации — обновить `WARP_DOMAINS` в локальном `config.env`.

---

## Замена серверов

### Замена иностранного exit-сервера (Latvia)

Самый частый случай — IP заблокирован, нужен новый. **Клиентские ссылки НЕ меняются.**

```bash
# Купить новый VPS, получить IP и root-пароль
ssh root@<RUSSIA_IP>
/opt/vpn-deploy/deploy.sh <НОВЫЙ_IP> '<ПАРОЛЬ>'
```

Скрипт:
1. Развернёт Xray + WARP на новом сервере
2. Обновит outbound на Russia (новый IP + ключи)
3. Прогонит тест
4. Выдаст ссылки (те же, что и были)

### Замена российского сервера (Russia)

Редкий случай — нужен новый российский VPS. **Клиентские ссылки ИЗМЕНЯТСЯ** (новые Reality-ключи).

1. Поднять новый Ubuntu-сервер в России
2. Установить зависимости:
```bash
apt update && apt install -y sshpass gcc make git unzip wget
```
3. Установить Xray:
```bash
cd /tmp
wget -q "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" -O xray.zip
unzip -o xray.zip xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray
```
4. Установить ByeDPI:
```bash
cd /tmp && git clone --depth 1 https://github.com/hufrea/byedpi.git
cd byedpi && make && cp ciadpi /usr/local/bin/byedpi
```
5. Скопировать конфиги и скрипты:
```bash
scp deploy.sh config.env root@<НОВЫЙ_IP>:/opt/vpn-deploy/
```
6. Запустить `dev/setup-russia-router.sh` (отредактировав IP/ключи) или настроить вручную по образцу `dev/VPN.md`
7. Разослать всем пользователям новые VLESS-ссылки

### Замена всей цепочки (оба сервера)

1. Сначала поднять и настроить **Russia** (см. выше)
2. Затем задеплоить **Latvia** через `deploy.sh` с Russia
3. Разослать новые ссылки

---

## config.env

```bash
NUM_USERS=11
XRAY_PORT=8443
SNI="www.github.com"
FINGERPRINT="chrome"
BYEDPI_PORT=1080
BYEDPI_ARGS="--split 1+s --disorder 1 --oob 1 --tlsrec 1+s"
BYPASS_DOMAINS=("domain:youtube.com" "domain:googlevideo.com" ...)
WARP_ENABLED=true
WARP_DOMAINS=("domain:openai.com" "domain:claude.ai" ...)
```

- **BYPASS_DOMAINS** — домены через ByeDPI на Russia (рос. IP)
- **WARP_DOMAINS** — домены через WARP на Latvia (IP Cloudflare)
- Всё остальное — напрямую через Latvia (латвийский IP)

## Маршрутизация

```
┌────────────────────────────────────────────────┐
│ Russia (Xray router)                           │
│                                                │
│ domain:youtube.com     → [bypass] → ByeDPI     │
│ domain:googlevideo.com → [bypass] → ByeDPI     │
│ domain:ytimg.com       → [bypass] → ByeDPI     │
│ ...                                            │
│                                                │
│ всё остальное → [latvia] → VLESS → Latvia:8443 │
└────────────────────────────────────────────────┘

┌────────────────────────────────────────────────┐
│ Latvia (Xray exit)                             │
│                                                │
│ domain:openai.com      → [warp] → WARP:40000   │
│ domain:claude.ai       → [warp] → WARP:40000   │
│ ...                                            │
│                                                │
│ всё остальное → [direct] → Интернет            │
└────────────────────────────────────────────────┘
```

## Требования

- **Russia**: Ubuntu 20.04+, Xray, ByeDPI
- **Latvia**: Ubuntu 20.04+ (чистый, скрипт ставит всё сам)
- Оба сервера: root-доступ, публичный IP
