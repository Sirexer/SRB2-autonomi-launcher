# Сборка и выпуск релиза

[English](building.md) | **Русский**

## Flutter

Нужен Flutter **3.47.9** — та же версия, что в CI (`FLUTTER_VERSION` в
`.github/workflows/build.yml`). С Flutter 3.50.0 лаунчер на части ПК падал
внутри драйвера NVIDIA (`nvwgf2umx.dll`), поэтому версия закреплена; меняйте
её осознанно и проверяйте сборку для Windows.

```bash
git clone --depth 1 -b 3.47.9 https://github.com/flutter/flutter.git ~/flutter
```

Добавьте `~/flutter/bin` в PATH. Скрипты ниже делают то же, что CI: дата,
коммит, версия Flutter и версия лаунчера в сборке, база GeoIP, библиотеки
музыки, `antd` и упаковка.

## Linux

Ubuntu (в том числе в WSL; для AppImage, который запустится на большинстве
дистрибутивов, — Ubuntu 22.04, как в CI):

```bash
sudo apt-get install -y git curl unzip xz-utils zip python3 file clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libasound2-dev libgme0 libopenmpt0
```
```bash
bash packaging/build_linux.sh
```

Результат — `SRB2-Autonomi-Launcher-x86_64.AppImage` (сама программа —
`build/linux/x64/release/bundle/`). В WSL держите репозиторий в файловой
системе Linux (`~/...`), а не в `/mnt/c`: там сборка в разы медленнее.

Звук (`flutter_soloud`) идёт через ALSA — нужен `libasound2-dev`. Без
системных `libopus` и `libogg` собирайте с `NO_OPUS_OGG_LIBS=1` (скрипт так и
делает).

## Windows

Git, Visual Studio 2022 (или Build Tools) с «Desktop development with C++»;
по желанию Python (база стран) и MSYS2 в `C:\msys64` (libopenmpt/libgme для
плеера). В PowerShell из папки репозитория:

```bash
powershell -ExecutionPolicy Bypass -File packaging\build_windows.ps1
```

Результат — `SRB2-Autonomi-Launcher-windows-x64.zip` (сама программа —
`build\windows\x64\runner\Release\`). `antd` скрипт качает с GitHub, если не
вышло — с зеркала на GitLab, а если и там нет — берёт копию из папки данных
лаунчера.

## Тесты

```bash
flutter test
```
```bash
flutter analyze
```

## Что идёт в сборку

| Что | Откуда | Как |
|---|---|---|
| Языки | `lang/` | CMake (`install(DIRECTORY ../lang)`) |
| Темы | `themes/` | CMake (`install(DIRECTORY ../themes)`) |
| Репозиторий по умолчанию | `packaging/pointer.txt` | скрипты сборки и CI |
| Свои игры (BlanKart) | `packaging/another_games.json` | CMake (любой `flutter build`), скрипты сборки и CI |
| Указание авторства данных | `packaging/NOTICE.txt` | скрипты сборки и CI |
| Демон Autonomi | релиз [ant-sdk](https://github.com/WithAutonomi/ant-sdk) | `packaging/fetch_antd.sh`, скрипт Windows |
| Страны серверов | база DB-IP Lite | `tools/build_geoip.py` → `assets/geoip/country.bin` |
| Флаги | [flag-icons](https://github.com/lipis/flag-icons) | `tools/render_flags.js` → `assets/flags/` |
| Данные прогресса Legacy/Kart | исходники игр | `tools/gen_progress_defaults.py` |

Без базы GeoIP (сборка из исходников без скрипта) страна сервера просто не
показывается; собрать её вручную:

```bash
python3 tools/build_geoip.py assets/geoip/country.bin
```

## Выпуск релиза

1. Поставьте тег `beta-<что-то>` или `v<версия>` (например, `beta-release3`) и
   отправьте его в публичный репозиторий. Workflow `.github/workflows/build.yml`
   соберёт Windows и Linux и создаст релиз с файлами
   `SRB2-Autonomi-Launcher-windows-x64.zip` и
   `SRB2-Autonomi-Launcher-x86_64.AppImage`.
2. Напишите описание релиза — его показывает окно обновления в лаунчере
   («Что нового»; Markdown: заголовки, списки, жирный).

Лаунчер ищет файлы релиза по этим именам, поэтому не переименовывайте их.

**Версия лаунчера** — тег релиза: CI передаёт его в
`--dart-define=BUILD_VERSION=<тег>`. Локальные скрипты берут переменную
окружения `BUILD_VERSION` или тег на текущем коммите:

```bash
BUILD_VERSION=beta-release3 bash packaging/build_linux.sh
```

В PowerShell — `$env:BUILD_VERSION = 'beta-release3'` перед запуском скрипта.
Как лаунчер сравнивает версии и ставит обновление — в
[internals.ru.md](internals.ru.md#обновление-лаунчера).
