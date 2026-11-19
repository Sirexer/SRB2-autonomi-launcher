# Свои игры (JSON)

[English](custom-games.md) | **Русский**

Кроме встроенных игр (SRB2, SRB2 Legacy, SRB2Kart, Ring Racers) лаунчер
поддерживает **свои игры** — форки, которые ведут себя как одна из встроенных
(например, [BlanKart](https://codeberg.org/NepDisk/blankart) — форк
SRB2Kart). Своя игра описывается в JSON; поведение (запуск, параметры, скины,
цвета, загрузка аддонов с сервера) берётся у основы (`base`), а отличия —
файлы игры, сборки, мастер-серверы, сетевой протокол — задаются в описании.

## Где добавить

- **Первый запуск.** Мастер предлагает игры из `another_games.json` рядом с
  лаунчером (в сборке он уже есть, там BlanKart). Неотмеченная игра не
  добавляется.
- **Настройки → Игры → «Добавить игры из JSON...».** Файл может описывать одну
  игру или несколько — тогда лаунчер покажет список, и вы выберете, какие
  добавить. Игра с тем же `id` заменяется новым описанием.

Там же, в Настройки → Игры:

- встроенные игры, кроме Sonic Robo Blast 2, можно **выключить** — их не будет
  в переключателе игр (настройки и файлы остаются, включить можно в любой
  момент);
- свою игру можно выключить или **убрать** из лаунчера: сама игра на диске
  не трогается, а вернуть её можно только снова из JSON;
- кнопка **экспорта** сохраняет описание своей игры в файл (вместе с иконкой),
  чтобы поделиться им.

## Формат файла

Одна игра — объект; несколько — список или `{"games": [...]}`:

```json
{
  "games": [
    {
      "id": "srb2blankart",
      "name": "BlanKart",
      "full_name": "SRB2Kart: BlanKart",
      "base": "srb2kart",
      "version": "2.0",
      "protocol": { "base": "ringracers", "packet_version": 2, "...": "см. ниже" },
      "master_api": "kart",
      "masters": ["https://ms.blankart.cc/MS/1"],
      "mod_version": 12,
      "main_file": "main.pk3",
      "download_path": "addons/DOWNLOAD",
      "executables": {
        "windows": ["blankart.exe"],
        "linux": ["blankart"]
      },
      "linux_data_folders": [".srb2kart-v2"],
      "base_addons": true,
      "own_files": ["main.pk3", "mappatch.pk3", "patch.pk3", "blanmusic.pk3"],
      "icon": "blankart.png"
    }
  ]
}
```

Обязательные поля:

| Поле | Что это |
|---|---|
| `id` | Код игры: 2–41 символ, строчные латинские буквы, цифры, `_`, `-`, `.`. Не может совпадать со встроенной игрой. По нему хранятся настройки игры и ищутся аддоны (`games` в манифесте). |
| `name` | Короткое название (в переключателе, подписях). |
| `base` | Основа: `srb2`, `srb2legacy`, `srb2kart` или `drrr`. |

Необязательные (без них берётся значение основы):

| Поле | Что это |
|---|---|
| `full_name` | Полное название (по умолчанию — `name`). |
| `version` | Версия игры для подписи. |
| `icon` | Иконка (PNG): путь относительно файла JSON или `data:image/png;base64,...`. Без неё — иконка основы. |
| `protocol` | Сетевой протокол опроса серверов: имя встроенного (`srb2`, `srb2legacy`, `srb2kart`, `ringracers`, `blankart`) или объект с описанием — см. «Протокол». |
| `master_api` | Вид мастер-сервера: `srb2` (`/servers`) или `kart` (`/games/<приложение>/<mod_version>/servers`). |
| `masters` | Мастер-серверы по умолчанию (список). |
| `mod_version`, `mod_id` | MODVERSION / MODID игры: по ним мастер-сервер отдаёт её серверы и сообщает о новой версии. |
| `main_file` | Файл, по которому узнаётся папка игры. |
| `download_path` | Папка загрузок аддонов внутри папки игры (например `"DOWNLOAD"` или `"addons/DOWNLOAD"`). |
| `gametypes` | Режимы игры для фильтра серверов. |
| `has_rooms` | Есть ли у мастер-сервера комнаты. |
| `executables` | Имена сборок: `{"windows": [...], "linux": [...]}`; первое — команда по умолчанию. |
| `executable_hints` | Слова в имени файла сборки, по которым лаунчер догадывается, что это эта игра (по умолчанию — `id`). |
| `linux_data_folders` | Папки игры на Linux относительно домашней (для подсказки). |
| `palette_files`, `map_files`, `skin_files`, `music_files` | Файлы игры, из которых берутся палитра, карты, скины и музыка. |
| `picture_inside_maps` | Картинки карт лежат внутри файлов карт. |
| `base_addons` | `true` — показывать и аддоны основы (форк их загружает). |
| `own_files` | Файлы самой игры с расширением аддонов (`.pk3`) — их нет в списке «В папке игры». |

Ошибки в описании (нет поля, неизвестная основа или протокол) показываются
в окне выбора игр — такую игру добавить нельзя, остальные из файла можно.

## Протокол

Лаунчер опрашивает серверы игры напрямую (UDP): спрашивает serverinfo
(название, карта, игроки, аддоны) и список игроков, а аддоны с сервера может
скачать до подключения. У форков пакеты часто чуть отличаются — другие номера
пакетов или смещения полей. Тогда `protocol` описывается объектом: `base` —
встроенный протокол, на который он похож, остальные поля — отличия от него
(всё, чего нет, берётся у основы). Полное описание протокола BlanKart — в
[packaging/another_games.json](../packaging/another_games.json).

| Поле | Что это |
|---|---|
| `base` | Обязательное: `srb2`, `legacy`, `srb2kart`, `ringracers` или `blankart`. |
| `application` | SRB2APPLICATION, который сервер присылает в serverinfo. |
| `packet_version`, `version`, `subversion` | PACKETVERSION, VERSION и SUBVERSION игры: сервер отвечает, только если они совпадают. |
| `has_packet_version_prefix` | Ответ начинается с `_255` и packetversion (2.2 и новее; в 2.1 — нет). |
| `version_format` | Как показывать версию: `srb2` (VERSION 202, SUBVERSION 15 → «2.2.15») или `major.minor` (2 и 4 → «2.4»). |
| `packets` | Номера пакетов: `client_quit`, `ask_info`, `server_info`, `player_info`, `request_file`, `file_fragment`, `file_ack`, `file_received`, `tell_files_needed`, `more_files_needed` (`-1` — пакета нет). |
| `server_info` | Смещения полей serverinfo от начала данных пакета: `application`, `version`, `players`, `refuse_reason`, `gametype`, `modified`, `flags`, `file_count`, `level_time`, `server_name`, `map_name`, `map_title`, `act_num`, `is_zone`, `http_source`, `avg_power_level`, `file_needed`. `null` — поля нет (`refuse_reason`, `map_name`, `http_source`, `avg_power_level`). |
| `player_info` | Запись игрока в plrinfo: `size` (размер записи), смещения `team`, `skin`, `score`, `time`; `skin_wide` — скин 2 байта, а не 1. |
| `file_entry_has_folder` | В записи файла есть байт «это папка» (SRB2 2.2). |
| `file_hash_bytes` | Размер контрольной суммы файла: 16 (MD5) или, например, 8 (XXH3-64 всего файла, как у BlanKart; лаунчер считает его сам). |
| `file_entry_extra` | Байты после контрольной суммы в записи файла (BlanKart: compatmode). |
| `preload_files` | `false` — не загружать аддоны сервера заранее (`-file`), игра грузит их сама при подключении. Нужно, если игра сверяет не только файлы, но и то, как они загружены (BlanKart: compatmode — с `-file` он может не совпасть с сервером, и игра пишет «You have the wrong addons loaded»). |
| `request_file_with_name` | В запросе файла (PT_REQUESTFILE) после номера идёт имя. |
| `legacy_file_transfer` | Старая передача файлов (SRB2Kart, SRB2 2.1): фрагменты подтверждаются на уровне сети, без PT_FILEACK. |
| `will_send` | Как читать «отдаст ли сервер файл»: `srb2` или `kart`. |
| `gametype_names` | Режим игры приходит числом: `{"2": "Race", "3": "Battle"}`; `null` — строкой. |
| `base_skins` | Встроенные скины по номеру — для списка игроков. |

Смещения и номера берутся из исходников игры (у SRB2-подобных —
`src/d_clisrv.h` / `src/netcode/protocol.h`, структуры `serverinfo_pak` и
`plrinfo`). Ошибка в описании протокола показывается так же, как другие
ошибки описания игры.
