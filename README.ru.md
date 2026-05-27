# xray-container

[English](README.md) · [Русский](README.ru.md)

xray-core, упакованный под контейнерный рантайм MikroTik RouterOS. На
старте качает подписку [Remnawave](https://remna.st/), собирает полный
xray-конфиг (балансировщик по всем VLESS-серверам, observatory,
sniffing, bypass-правила) и обеспечивает прозрачный VPN-роутинг для
всего LAN с селективным bypass'ом — `.ru`, популярные русские сервисы
и `geoip:ru` идут direct, всё остальное — через VLESS-балансировщик.

Проверено на **MikroTik hAP ax3** (IPQ-6010, ARM64, 1 ГБ RAM,
RouterOS 7.x).

## Quick install

Что нужно:

- Роутер на RouterOS 7.10+, установленный extra-пакет `container`,
  USB-флешка или microSD, видимая в `/disk/print` (примеры ниже
  предполагают slot `usb1`).
- Docker / nerdctl на сборочной машине (на macOS работает Colima)
  с поддержкой `linux/arm64`.
- Физический доступ к роутеру для одного короткого нажатия кнопки
  reset.

### 1. Включить режим контейнеров (один раз)

В WinBox или через SSH на роутере:

```routeros
/system/device-mode/print
# если "container: no", выполнить:
/system/device-mode/update container=yes
# коротко нажать кнопку reset в течение 60 секунд
/system/device-mode/print
# должно быть "container: yes"
```

### 2. Собрать образ

```bash
git clone https://github.com/davydovd/xray-container ~/opensource/xray-container
cd ~/opensource/xray-container
./build.sh --export
# → dist/xray-container.tar (~100 МБ, linux/arm64)
```

### 3. Указать свою ссылку подписки

Открой `routeros/01-container-setup.rsc` и замени placeholder:

```routeros
:local subscriptionUrl       "https://CHANGEME.example/your-token"
```

на свою реальную Remnawave-ссылку. **Не коммить настоящую ссылку** —
`routeros/*.local.rsc` в `.gitignore` именно для этого, используй такой
суффикс для приватных копий.

### 4. Залить три файла на роутер

Замени `192.168.88.1` на IP своего роутера:

```bash
ROUTER=192.168.88.1
scp dist/xray-container.tar              admin@$ROUTER:usb1/
scp routeros/01-container-setup.rsc      admin@$ROUTER:usb1/
scp routeros/02c-routing-rules.rsc       admin@$ROUTER:usb1/
```

Альтернативно — перетащить эти три файла в `usb1/` через WinBox →
Files.

### 5. Создать контейнер

В терминале WinBox / SSH:

```routeros
/import file=usb1/01-container-setup.rsc
/log/print follow where topics~"container"
# дождаться строк:
#   [Z] REDIRECT rules installed (PREROUTING tcp -> :12345); ip_forward=1
#   [Z] starting xray (config=/etc/xray/config.json)
#   [Z] xray pid=...
# выйти из follow по Ctrl-C
```

### 6. Добавить bridge контейнера в LAN list

```routeros
/interface/list/member/add list=LAN interface=br-containers
```

Делается один раз — это разрешает стандартным правилам firewall'а
пропускать трафик в контейнер и обратно.

### 7. Включить прозрачную маршрутизацию

```routeros
/import file=usb1/02c-routing-rules.rsc
```

### 8. Проверка с LAN-клиента

```bash
curl --silent --max-time 15 https://ifconfig.co
# → IP одного из твоих VLESS-серверов (НЕ провайдера)

curl --silent --max-time 10 https://ya.ru -o /dev/null -w "%{remote_ip}\n"
# → IP в .ru (direct, bypass)
```

Готово. Весь LAN теперь идёт через VPN по умолчанию, `.ru` и
захардкоженный список русских сервисов — напрямую.

## Как это работает

```
LAN-клиент                RouterOS                     namespace контейнера
─────────                 ────────                     ────────────────────
curl https://x.com ─────► mangle prerouting
                          ├─ src=container         → accept (без loop)
                          ├─ dst=private/local     → accept (bypass)
                          ├─ dst=53                → accept (DNS direct)
                          └─ in=LAN, tcp           → mark-routing via-xray
                                ↓
                          /ip/route via-xray
                          default → gw=172.20.0.2 (контейнер)
                                ↓
                          пакет уходит через veth, original dst не тронут
                                ↓
                                                    iptables -t nat
                                                    PREROUTING tcp
                                                    REDIRECT --to-ports 12345
                                                          ↓
                                                    xray dokodemo-door
                                                    followRedirect=true
                                                    читает SO_ORIGINAL_DST
                                                          ↓
                                                    sniff SNI из TLS hello
                                                          ↓
                                                    routing rules:
                                                    ├─ private          → direct
                                                    ├─ BYPASS_DOMAIN    → direct
                                                    ├─ BYPASS_GEOIP     → direct
                                                    └─ default          → balancer
                                                                            ↓
                                                                    VLESS outbound
                                                                    (leastPing)
```

Почему mark-routing, а не `dst-nat REDIRECT` прямо на роутере:
`SO_ORIGINAL_DST` читается из conntrack. Если dst-nat выполняется на
хосте RouterOS, запись conntrack остаётся в hostовом netns — для xray
внутри контейнера она невидима. REDIRECT внутри контейнера ставит
conntrack и xray в один namespace, и lookup работает. Дополнительно,
ядро MikroTik container не загружает модуль TPROXY iptables, так что
классический `iptables -t mangle TPROXY` тоже не вариант.

QUIC (UDP/443) дропается в `02c-routing-rules.rsc`, чтобы браузеры
откатывались на TCP TLS — поскольку SO_ORIGINAL_DST работает только
для TCP, UDP-трафик иначе обошёл бы xray полностью. Чтобы отключить
блокировку — поправь `:local blockQuic false` в rsc.

## Структура репозитория

```
.
├── Containerfile                  multi-stage Alpine + xray + supervisor
├── build.sh                       сборка + экспорт OCI tar для RouterOS
├── scripts/
│   └── entrypoint.sh              fetch → parse → build → run + цикл refresh
└── routeros/
    ├── 01-container-setup.rsc     veth / bridge / envs / container
    └── 02c-routing-rules.rsc      mark-routing + LAN→container gateway
```

## Конфигурация

Все настройки — переменные окружения контейнера, задаются через
`/container/envs` в `01-container-setup.rsc`. Меняй значения в верхней
части файла и переимпортируй.

| Имя                           | Default        | Назначение                                                              |
| ----------------------------- | -------------- | ----------------------------------------------------------------------- |
| `SUBSCRIPTION_URL`            | (обязательно)  | URL подписки Remnawave                                                  |
| `SUBSCRIPTION_USER_AGENT`     | `Xray/26.3.27` | UA при fetch — управляет форматом ответа Remnawave                      |
| `SUBSCRIPTION_FORMAT`         | `auto`         | `auto` / `xray-json` / `base64`                                         |
| `REFRESH_INTERVAL_SECONDS`    | `43200`        | 12 ч — частота повторной выгрузки подписки                              |
| `TPROXY_PORT`                 | `12345`        | Внутренний порт `dokodemo-door` (цель REDIRECT)                         |
| `SOCKS_PORT`                  | `10808`        | SOCKS5 (также доступен из LAN для ручных клиентов)                      |
| `DNS_PORT`                    | `10853`        | DNS dokodemo-door                                                       |
| `REDIRECT_ENABLED`            | `1`            | Установить `iptables -t nat REDIRECT` внутри контейнера; обязательно    |
|                               |                | для mark-routing схемы                                                  |
| `BALANCER_STRATEGY`           | `leastPing`    | `leastPing` / `random` / `roundRobin`                                   |
| `OBSERVATORY_INTERVAL`        | `5m`           | Интервал зондирования VLESS-серверов                                    |
| `LOG_LEVEL`                   | `warning`      | `debug` / `info` / `warning` / `error` — для отладки ставь `info`       |
| `BYPASS_PRIVATE`              | `1`            | Если `1`, добавляет обход geoip/geosite:private                         |
| `BYPASS_DOMAIN`               | см. rsc        | CSV xray-матчеров `direct` (regexp/domain/keyword/...)                  |
| `BYPASS_GEOIP`                | `ru`           | CSV GeoIP-кодов, идущих `direct`                                        |

### Подстройка bypass-списка

Поправь `bypassDomain` / `bypassGeoip` в `01-container-setup.rsc`,
затем:

```routeros
/import file=usb1/01-container-setup.rsc
```

Скрипт идемпотентный — он остановит контейнер, пересоздаст envs и
стартует заново.

Префиксы domain-матчеров (xray-синтаксис):

- `domain:vk.com`     — `vk.com` и любой саб
- `regexp:\.ru$`      — регексп по FQDN
- `keyword:apple`     — substring
- `full:example.org`  — точное совпадение
- `geosite:cn`        — geosite-группа из вшитого geosite.dat

> Кириллица в `BYPASS_DOMAIN` теряется при `/import` (RouterOS
> вырезает не-ASCII символы из string-литералов). Держи это значение
> чисто ASCII — для русских сервисов на иностранных TLD используй
> явные `domain:` записи вместо `regexp:\.рф$`.

## Эксплуатация

### Принудительное обновление подписки

```routeros
/container/stop xray
/container/start xray
```

### Пересоздать контейнер после пересборки образа

```bash
./build.sh --export
scp dist/xray-container.tar admin@$ROUTER:usb1/
```

```routeros
/container/stop xray
/container/remove xray
/import file=usb1/01-container-setup.rsc
```

### Временно отключить VPN (весь LAN идёт напрямую)

```routeros
/ip/firewall/mangle/disable [find comment~"xray-mark"]
```

Включить обратно:

```routeros
/ip/firewall/mangle/enable [find comment~"xray-mark"]
```

### Полное удаление

```routeros
/ip/firewall/mangle/remove [find comment~"xray-mark"]
/ip/firewall/filter/remove [find comment~"xray-mark"]
/ip/route/remove [find routing-table="via-xray"]
/routing/table/remove [find name="via-xray"]
/container/stop xray
/container/remove xray
/container/envs/remove [find list="xray-env"]
/interface/list/member/remove [find interface=br-containers]
/interface/bridge/port/remove [find interface=veth-xray]
/interface/veth/remove [find name=veth-xray]
/ip/address/remove [find interface=br-containers]
/interface/bridge/remove [find name=br-containers]
```

## Траблшутинг

**`/import` падает на `bad parameter mounts` / `mount`.** В device-mode
твоего RouterOS не разрешены bind-mounts. В поставляемом скрипте
mounts закомментированы именно для этого — state и логи xray живут в
writable-слое контейнера и теряются только при `container/remove`, не
при `stop/start`.

**`failed to call getsockopt > no such file or directory` в логах
xray.** REDIRECT-правило не установилось внутри контейнера. Открой
shell (`/container/shell xray`) и выполни `iptables -t nat -L XRAY -n
-v` — цепочка должна существовать. Если нет — проверь, что
`REDIRECT_ENABLED=1` есть в `/container/envs/print where
list="xray-env"`.

**`SUBSCRIPTION_URL is required` в логах.** Список envs контейнера
пустой — скорее всего ты сделал `/import 01-container-setup.rsc`
ещё с `subscriptionUrl=CHANGEME`, а потом переимпортировал, но без
пересоздания env list. Выполни `/container/envs/remove [find
list="xray-env"]` и снова импортируй.

**`xray run -test` отклоняет сгенерированный конфиг.** Какой-то
VLESS-сервер в подписке использует комбинацию транспорт/security,
которую парсер ещё не поддерживает. Подними `LOG_LEVEL=info`,
перезапусти и посмотри строку, где URI был отклонён. Отвергнутый
конфиг сохраняется в `/etc/xray/config.json.new.rejected` внутри
контейнера для анализа (`/container/shell xray`).

**Браузер показывает прямой IP для иностранных сайтов.** Либо
проскакивает QUIC (проверь `:local blockQuic true` в
`02c-routing-rules.rsc`), либо клиент использует DoH/DoT в обход
роутера. xray матчит по SNI, так что DoH сам по себе ничего не
ломает — но если браузер держит долгоживущий QUIC-коннект, он не
откатывается на TCP.

**Счётчики на dst-nat / mark-routing правиле — нули.** Bridge
`br-containers` не в `/interface/list/member` для `LAN`. Добавь:
`/interface/list/member/add list=LAN interface=br-containers`.

## Безопасность

- Никогда не коммить настоящую Remnawave-ссылку — она даёт полный
  доступ к твоему аккаунту. `routeros/*.local.rsc` в `.gitignore` —
  используй такой суффикс для приватных копий.
- xray внутри контейнера запускается от UID 65532. Для iptables и
  conntrack нужен CAP_NET_ADMIN — RouterOS даёт его всем контейнерам
  по умолчанию.
- Базы `geoip.dat` / `geosite.dat` вшиты в образ на момент сборки;
  чтобы обновить — пересобери образ с новым `XRAY_VERSION`.

## Лицензия

Исходники этого репозитория: MIT.
Вшитый xray-core остаётся под
[MPL-2.0](https://github.com/XTLS/Xray-core/blob/main/LICENSE).
