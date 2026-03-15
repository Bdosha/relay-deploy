# VPN Deploy

Автоматическое развёртывание двухсерверного VPN (VLESS + Reality) за одну команду.

## Архитектура

```
Клиент (AmneziaVPN)
  → Relay:443 (Россия, iptables DNAT)
    → Exit:8443 (Xray VLESS+Reality)
      → Интернет
```

**Relay** — тупой TCP-проброс (iptables NAT). Постоянный сервер.
**Exit** — Xray VPN-сервер. Расходный материал — легко заменить на новый IP.

## Файлы

| Файл | Где запускать | Назначение |
|---|---|---|
| `deploy.sh` | На relay | Поднимает exit-ноду, обновляет relay, выдаёт ссылки |
| `setup-relay.sh` | На новом relay | Одноразовая настройка relay-сервера с нуля |
| `config.env` | — | Настройки: кол-во юзеров, SNI, порт |
| `links-*.txt` | — | Сгенерированные VLESS-ссылки (создаются после деплоя) |

## Быстрый старт

### Новый exit-сервер (relay уже настроен)

```bash
ssh root@<RELAY_IP>
/opt/vpn-deploy/deploy.sh <EXIT_IP> '<ROOT_PASSWORD>'
```

Скрипт сделает всё сам: установит Xray, сгенерирует ключи, настроит systemd/logrotate/DNS, обновит iptables на relay, прогонит тест и выдаст готовые VLESS-ссылки.

### Всё с нуля (2 свежих Ubuntu-сервера)

```bash
# 1. Настроить relay (один раз)
scp setup-relay.sh root@<RELAY_IP>:/tmp/
ssh root@<RELAY_IP> 'bash /tmp/setup-relay.sh'

# 2. Положить скрипты на relay
scp deploy.sh config.env root@<RELAY_IP>:/opt/vpn-deploy/

# 3. Задеплоить exit-ноду
ssh root@<RELAY_IP>
/opt/vpn-deploy/deploy.sh <EXIT_IP> '<ROOT_PASSWORD>'
```

## Что делает deploy.sh (10 шагов)

1. Проверяет зависимости (sshpass, /tmp/xray)
2. Тестирует SSH до exit-сервера
3. Устанавливает Xray на exit
4. Генерирует свежую пару Reality-ключей + shortId
5. Создаёт конфиг Xray с N свежими UUID (NUM_USERS из `config.env`)
6. Настраивает systemd-сервис, запускает Xray
7. Настраивает logrotate (7 дней, copytruncate) и DNS (FallbackDNS IPv4)
8. Копирует SSH-ключ relay → exit (для доступа без пароля)
9. Обновляет iptables на relay (DNAT на новый exit IP)
10. Прогоняет полный тест: TCP-порт + VPN-туннель (curl через VLESS → google.com)

## config.env

```bash
NUM_USERS=11
XRAY_PORT=8443
SNI="www.github.com"
FINGERPRINT="chrome"
RELAY_PORTS=(443 8444)
```

Никаких секретов — можно коммитить. UUID генерируются заново при каждом деплое.

- **NUM_USERS** — сколько VLESS-аккаунтов создать
- **SNI** — домен для Reality-маскировки (должен поддерживать TLS 1.3)
- **RELAY_PORTS** — какие порты relay пробрасывает на exit

## Добавить/убрать пользователя

Поменять `NUM_USERS` в config.env и перезапустить деплой. Все ссылки пересоздаются.

## Замена exit-сервера (смена IP)

```bash
# Купить новый VPS, получить IP и пароль
/opt/vpn-deploy/deploy.sh <НОВЫЙ_IP> '<НОВЫЙ_ПАРОЛЬ>'
# Разослать пользователям новые ссылки из links-*.txt
```

Скрипт сам уберёт старые iptables-правила и поставит новые.

## Безопасность

- **config.env** не содержит секретов — можно коммитить
- Reality-ключи и UUID генерируются заново при каждом деплое
- SSH-ключ relay → exit копируется автоматически
- **links-*.txt** содержат VLESS-ссылки — в git не попадают (.gitignore)
- exit-сервер по умолчанию принимает пароль — рекомендуется отключить после деплоя

## Требования

- **Relay**: Ubuntu 20.04+, sshpass, iptables
- **Exit**: Ubuntu 20.04+ (чистый, скрипт ставит всё сам)
- Оба сервера: root-доступ, публичный IP
