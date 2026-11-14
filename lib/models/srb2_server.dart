import 'dart:convert';
import 'dart:typed_data';

/// Кусок текста SRB2 одного цвета: 0 — обычный, 1–15 — коды \x81–\x8F
/// (magenta, yellow, green, blue, red, gray, orange, sky, purple, aqua,
/// peridot, azure, brown, rosy, invert).
class Srb2TextSpan {
  final String text;
  final int color;
  const Srb2TextSpan(this.text, this.color);
}

/// Строки SRB2 (имена серверов и т.п.).
class Srb2Text {
  Srb2Text._();

  /// Разбирает байты в точности как игра: \x80–\x8F переключают цвет
  /// (\x80 — сброс), всё вне шрифта SRB2 (0x20–0x7E) не показывается.
  /// UTF-8 не угадываем: имена вида "\xC3\x88Vega" — это мусорный байт и
  /// код цвета, а не буква "È".
  static List<Srb2TextSpan> parse(List<int> bytes) {
    final spans = <Srb2TextSpan>[];
    final buf = StringBuffer();
    var color = 0;

    void flush() {
      if (buf.isEmpty) return;
      if (spans.isNotEmpty && spans.last.color == color) {
        spans[spans.length - 1] = Srb2TextSpan(spans.last.text + buf.toString(), color);
      } else {
        spans.add(Srb2TextSpan(buf.toString(), color));
      }
      buf.clear();
    }

    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0) break;
      if (b >= 0x80 && b <= 0x8F) {
        flush();
        color = b - 0x80;
      } else if (b >= 0x20 && b < 0x7F || b > 0xFF) {
        // > 0xFF — не байт игры, а символ перевода (кириллица и т.п.).
        buf.writeCharCode(b);
      }
      i++;
    }
    flush();

    // Пробелы по краям всей строки и пустые куски — убираем.
    spans.removeWhere((x) => x.text.isEmpty);
    while (spans.isNotEmpty) {
      final t = spans.first.text.trimLeft();
      if (t.isNotEmpty) {
        spans[0] = Srb2TextSpan(t, spans.first.color);
        break;
      }
      spans.removeAt(0);
    }
    while (spans.isNotEmpty) {
      final t = spans.last.text.trimRight();
      if (t.isNotEmpty) {
        spans[spans.length - 1] = Srb2TextSpan(t, spans.last.color);
        break;
      }
      spans.removeLast();
    }
    return spans;
  }

  static String plain(List<Srb2TextSpan> spans) => spans.map((x) => x.text).join();

  /// Строка из SOC, как её читает игра (myfgets): `^0`–`^9` и `^A`–`^F` —
  /// коды цветов \x80–\x8F (`^4My level` — синее название), `^^` — сам `^`;
  /// `\XX` — байт в hex (`\82`), `\\` — сам `\`. Символы вне latin1 в SOC
  /// не бывает (он читается как latin1) — это текст лаунчера (перевод), они
  /// остаются как есть, и [parse] их сохраняет.
  static List<int> decodeSoc(String s) {
    final out = <int>[];
    int? hex(int i) => i < s.length ? int.tryParse(s[i], radix: 16) : null;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x5E && i + 1 < s.length) {
        // ^: ^^ — сам знак, ^0–^F — цвет; «^» перед другим знаком (как
        // «^2yellow^ room» в подсказках эмблем) — конец цвета, знак остаётся.
        final code = hex(i + 1);
        if (s[i + 1] == '^') {
          out.add(0x5E);
          i++;
        } else if (code != null) {
          out.add(0x80 + code);
          i++;
        } else {
          out.add(0x80);
        }
      } else if (c == 0x5C && i + 1 < s.length) {
        // \
        if (s[i + 1] == r'\') {
          out.add(0x5C);
          i++;
        } else {
          final hi = hex(i + 1), lo = hex(i + 2);
          out.add(hi == null || lo == null ? 0x3F : hi * 16 + lo);
          i += hi == null ? 1 : 2;
        }
      } else {
        out.add(c);
      }
    }
    return out;
  }

  /// Процентное кодирование (имена в списке мастер-сервера) → байты.
  static List<int> percentDecode(String s) {
    final out = <int>[];
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 0x25 && i + 2 < s.length) {
        final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
        if (v != null) {
          out.add(v);
          i += 2;
          continue;
        }
      }
      if (c < 0x80) {
        out.add(c);
      } else {
        out.addAll(utf8.encode(String.fromCharCode(c)));
      }
    }
    return out;
  }
}

/// Константы сетевого протокола SRB2 2.2.15 (src/netcode/protocol.h).
class Srb2Protocol {
  Srb2Protocol._();

  static const defaultPort = 5029;
  static const packetVersion = 5;
  static const headerSize = 8; // checksum(4) ack ackreturn packettype reserved

  // Номера пакетов (enum packettype_t).
  static const ptAskInfo = 12;
  static const ptServerInfo = 13;
  static const ptPlayerInfo = 14;
  static const ptTellFilesNeeded = 31;
  static const ptMoreFilesNeeded = 32;

  /// VERSION (202 = 2.2) и SUBVERSION (15) клиента 2.2.15.
  static const version = 202;
  static const subversion = 15;

  static const maxPlayers = 32;
  static const playerInfoSize = 36; // sizeof(plrinfo_pak)

  // serverinfo_pak.flags
  static const svLotsOfAddons = 0x20;
  static const svDedicated = 0x40;

  /// Смещения полей serverinfo_pak от начала данных пакета.
  static const _offFileNeeded = 406;
}

/// Сетевой протокол конкретной игры: номера пакетов, версия и раскладка
/// serverinfo_pak. Заголовок doomdata_t и контрольная сумма у SRB2 и
/// Ring Racers одинаковые.
class NetProtocol {
  /// SRB2APPLICATION, который сервер шлёт в serverinfo.
  final String application;
  final int packetVersion;
  final int version;
  final int subversion;

  /// Ответ начинается с `_255` и packetversion (2.2 и новее); в 2.1 — сразу
  /// с версии игры.
  final bool hasPacketVersionPrefix;

  /// Как показывать версию: SRB2 — "2.2.15" (VERSION 202), Ring Racers — "2.4".
  final String Function(int version, int subversion) formatVersion;

  final int ptClientQuit;
  final int ptAskInfo;
  final int ptServerInfo;
  final int ptPlayerInfo;
  final int ptRequestFile;
  final int ptFileFragment;
  final int ptFileAck;
  final int ptFileReceived;
  final int ptTellFilesNeeded;
  final int ptMoreFilesNeeded;

  /// В записи списка аддонов есть байт "это папка" (только SRB2 2.2.x).
  final bool fileEntryHasFolder;

  /// PT_REQUESTFILE содержит имя файла после номера (Ring Racers, SRB2Kart).
  final bool requestFileWithName;

  /// Старая передача файлов (SRB2Kart, как SRB2 2.1): фрагменты приходят
  /// "надёжными" пакетами с номером ack в заголовке и подтверждаются на
  /// уровне сети (ackreturn и PT_NOTHING), без PT_FILEACK/PT_FILERECEIVED.
  final bool legacyFileTransfer;

  /// Режим игры числом (SRB2Kart: 2 — Race, 3 — Battle); null — строкой.
  final Map<int, String>? gametypeNames;

  /// Встроенные скины по номеру (для списка игроков).
  final List<String> baseSkins;

  /// Старшие 4 бита статуса файла → отдаст ли сервер файл.
  final ServerFileSend Function(int code) willSend;

  /// Смещения полей serverinfo_pak от начала данных пакета (null — поля нет).
  final int offApplication;
  final int offVersion;
  final int offPlayers;

  /// refusereason (null — поля нет, SRB2Kart).
  final int? offRefuseReason;
  final int offGametype;
  final int offModified;
  final int offFlags;
  final int offFileCount;
  final int offLevelTime;
  final int offServerName;
  final int? offMapName;
  final int offMapTitle;
  final int offActNum;
  final int offIsZone;
  final int? offHttpSource;
  final int? offAvgPowerLevel;
  final int offFileNeeded;

  const NetProtocol._({
    required this.application,
    required this.packetVersion,
    required this.version,
    required this.subversion,
    this.hasPacketVersionPrefix = true,
    required this.formatVersion,
    required this.ptClientQuit,
    required this.ptAskInfo,
    required this.ptServerInfo,
    required this.ptPlayerInfo,
    required this.ptRequestFile,
    required this.ptFileFragment,
    required this.ptFileAck,
    required this.ptFileReceived,
    required this.ptTellFilesNeeded,
    required this.ptMoreFilesNeeded,
    required this.fileEntryHasFolder,
    required this.requestFileWithName,
    this.legacyFileTransfer = false,
    this.gametypeNames,
    required this.baseSkins,
    required this.willSend,
    required this.offApplication,
    required this.offVersion,
    required this.offPlayers,
    required this.offRefuseReason,
    required this.offGametype,
    required this.offModified,
    required this.offFlags,
    required this.offFileCount,
    required this.offLevelTime,
    required this.offServerName,
    required this.offMapName,
    required this.offMapTitle,
    required this.offActNum,
    required this.offIsZone,
    required this.offHttpSource,
    required this.offAvgPowerLevel,
    required this.offFileNeeded,
  });

  static String _srb2Version(int v, int s) => '${v ~/ 100}.${v % 100}.$s';
  static String _rrVersion(int v, int s) => '$v.$s';

  static ServerFileSend _srb2WillSend(int code) => switch (code) {
        1 => ServerFileSend.no,
        2 => ServerFileSend.tooLarge,
        _ => ServerFileSend.yes,
      };

  // Kart/Ring Racers: 1 — отдаст, 2 — скачивание выключено, 0 — слишком большой.
  static ServerFileSend _kartWillSend(int code) => switch (code) {
        1 => ServerFileSend.yes,
        2 => ServerFileSend.no,
        _ => ServerFileSend.tooLarge,
      };

  /// SRB2 2.2.15 (src/netcode/protocol.h).
  static const srb2 = NetProtocol._(
    application: 'SRB2',
    packetVersion: Srb2Protocol.packetVersion,
    version: Srb2Protocol.version,
    subversion: Srb2Protocol.subversion,
    formatVersion: _srb2Version,
    ptClientQuit: 11,
    ptAskInfo: Srb2Protocol.ptAskInfo,
    ptServerInfo: Srb2Protocol.ptServerInfo,
    ptPlayerInfo: Srb2Protocol.ptPlayerInfo,
    ptRequestFile: 15,
    ptFileFragment: 24,
    ptFileAck: 25,
    ptFileReceived: 26,
    ptTellFilesNeeded: Srb2Protocol.ptTellFilesNeeded,
    ptMoreFilesNeeded: Srb2Protocol.ptMoreFilesNeeded,
    fileEntryHasFolder: true,
    requestFileWithName: false,
    baseSkins: ['Sonic', 'Tails', 'Knuckles', 'Amy', 'Fang', 'Metal Sonic'],
    willSend: _srb2WillSend,
    offApplication: 2,
    offVersion: 18,
    offPlayers: 20,
    offRefuseReason: 22,
    offGametype: 23,
    offModified: 47,
    offFlags: 49,
    offFileCount: 50,
    offLevelTime: 55,
    offServerName: 59,
    offMapName: 91,
    offMapTitle: 99,
    offActNum: 148,
    offIsZone: 149,
    offHttpSource: 150,
    offAvgPowerLevel: null,
    offFileNeeded: Srb2Protocol._offFileNeeded,
  );

  /// SRB2 Legacy 2.1.30 (srb2-preservation/srb2-legacy, src/d_clisrv.h):
  /// протокол 2.1. Ответ PT_SERVERINFO начинается сразу с version/subversion
  /// (нет _255/packetversion/application), режим игры — числом, файлы — как
  /// в SRB2Kart (тот же 2.1): без PT_FILEACK, со старым кодом «отдаст»; в
  /// PT_REQUESTFILE — номер и имя файла.
  static const legacy = NetProtocol._(
    application: 'SRB2',
    packetVersion: 0,
    version: 201, // 2.1.x
    subversion: 30,
    hasPacketVersionPrefix: false,
    formatVersion: _srb2Version,
    ptClientQuit: 11,
    ptAskInfo: 12,
    ptServerInfo: 13,
    ptPlayerInfo: 14,
    ptRequestFile: 15,
    ptFileFragment: 24,
    // PT_FILEACK / PT_FILERECEIVED в 2.1 нет (legacyFileTransfer).
    ptFileAck: 25,
    ptFileReceived: 26,
    ptTellFilesNeeded: 29,
    ptMoreFilesNeeded: 30,
    fileEntryHasFolder: false,
    // Got_RequestFilePak (d_netfil.c): после номера — имя файла
    // (READSTRINGN), по нему сервер и ищет файл (SV_SendFile).
    requestFileWithName: true,
    legacyFileTransfer: true,
    gametypeNames: {
      0: 'Co-op',
      1: 'Competition',
      2: 'Race',
      3: 'Match',
      4: 'Team Match',
      5: 'Tag',
      6: 'Hide & Seek',
      7: 'CTF',
    },
    baseSkins: ['Sonic', 'Tails', 'Knuckles'],
    willSend: _kartWillSend,
    offApplication: 0,
    offVersion: 0,
    offPlayers: 2,
    offRefuseReason: null,
    offGametype: 4,
    offModified: 5,
    offFlags: 7,
    offFileCount: 8,
    offLevelTime: 14,
    offServerName: 18,
    offMapName: 50,
    offMapTitle: 58,
    offActNum: 107,
    offIsZone: 108,
    offHttpSource: null,
    offAvgPowerLevel: null,
    offFileNeeded: 109,
  );

  /// Dr. Robotnik's Ring Racers 2.4 (src/d_clisrv.h). Смещения проверены
  /// offsetof по упакованной структуре: после version/subversion идёт
  /// commit[4], нет mapname, есть avgpwrlv.
  static const ringRacers = NetProtocol._(
    application: 'RingRacers',
    packetVersion: 0,
    version: 2,
    subversion: 4,
    formatVersion: _rrVersion,
    ptClientQuit: 11,
    ptAskInfo: 12,
    ptServerInfo: 13,
    ptPlayerInfo: 14,
    ptRequestFile: 15,
    ptFileFragment: 28,
    ptFileAck: 29,
    ptFileReceived: 30,
    ptTellFilesNeeded: 37,
    ptMoreFilesNeeded: 38,
    fileEntryHasFolder: false,
    requestFileWithName: true,
    baseSkins: [], // в plrinfo скин не передаётся (0xFF)
    willSend: _kartWillSend,
    offApplication: 2,
    offVersion: 18,
    offPlayers: 24,
    offRefuseReason: 26,
    offGametype: 27,
    offModified: 51,
    offFlags: 53,
    offFileCount: 54,
    offLevelTime: 59,
    offServerName: 63,
    offMapName: null,
    offMapTitle: 95,
    offActNum: 144,
    offIsZone: 145,
    offHttpSource: 146,
    offAvgPowerLevel: 402,
    offFileNeeded: 404,
  );

  /// SRB2Kart 1.6 (Kart-Public v1.6, src/d_clisrv.h). Ближе к SRB2 2.1:
  /// нет refusereason, режим игры — число "как в ванилле", своя нумерация
  /// пакетов (PT_RESYNCH*, нет PT_FILEACK) и старая передача файлов.
  static const srb2Kart = NetProtocol._(
    application: 'SRB2Kart',
    packetVersion: 0,
    version: 1,
    subversion: 6,
    formatVersion: _rrVersion,
    ptClientQuit: 11,
    ptAskInfo: 12,
    ptServerInfo: 13,
    ptPlayerInfo: 14,
    ptRequestFile: 15,
    ptFileFragment: 24,
    ptFileAck: -1,
    ptFileReceived: -1,
    ptTellFilesNeeded: 32,
    ptMoreFilesNeeded: 33,
    fileEntryHasFolder: false,
    requestFileWithName: true,
    legacyFileTransfer: true,
    gametypeNames: {2: 'Race', 3: 'Battle'},
    baseSkins: ['Sonic', 'Tails', 'Knuckles', 'Eggman', 'Metal Sonic'],
    willSend: _kartWillSend,
    offApplication: 2,
    offVersion: 18,
    offPlayers: 20,
    offRefuseReason: null,
    offGametype: 22,
    offModified: 23,
    offFlags: 25,
    offFileCount: 26,
    offLevelTime: 31,
    offServerName: 35,
    offMapName: 67,
    offMapTitle: 75,
    offActNum: 124,
    offIsZone: 125,
    offHttpSource: 126,
    offAvgPowerLevel: null,
    offFileNeeded: 382,
  );

  /// Пакеты, которые сервер шлёт "надёжно" (ack в заголовке), нужно
  /// подтверждать — сейчас только фрагменты файлов SRB2Kart.
  static const ptNothing = 0;
}

/// Статус файла на сервере: отдаст ли его сервер при подключении.
enum ServerFileSend { yes, no, tooLarge }

/// Аддон, загруженный на сервере.
class ServerFile {
  final String name;
  final int size;
  final String md5; // 32 hex-символа в нижнем регистре
  final ServerFileSend willSend;
  final bool isFolder;

  const ServerFile({
    required this.name,
    required this.size,
    required this.md5,
    required this.willSend,
    required this.isFolder,
  });
}

/// Игрок на сервере (plrinfo_pak).
class ServerPlayer {
  final int num;
  final String name;

  /// 255 — зритель (или без команды), 1/2 — красная/синяя команда.
  final int team;
  final int skin;
  final int score;
  final int secondsInServer;

  /// Встроенные скины игры по номеру.
  final List<String> baseSkins;

  const ServerPlayer({
    this.baseSkins = const ['Sonic', 'Tails', 'Knuckles', 'Amy', 'Fang', 'Metal Sonic'],
    required this.num,
    required this.name,
    required this.team,
    required this.skin,
    required this.score,
    required this.secondsInServer,
  });

  bool get isSpectator => team == 255;

  /// Имя скина: базовые скины 2.2 идут первыми, остальные — из аддонов.
  String get skinName {
    if (skin == 255) return ''; // Ring Racers не присылает скин
    return skin < baseSkins.length ? baseSkins[skin] : 'Skin #$skin';
  }
}

/// Ответ сервера на PT_ASKINFO (serverinfo_pak).
class ServerInfo {
  final NetProtocol protocol;
  final int packetVersion;
  final String application;
  final int version;
  final int subversion;
  final int players;
  final int maxPlayers;

  /// 0 — можно зайти, 1 — вход закрыт, 2 — нет мест, 3 — вы забанены;
  /// -1 — сервер не сообщает (SRB2Kart).
  final int refuseReason;
  final String gametype;
  final bool modified;

  /// Имя сервера с цветами SRB2.
  final List<Srb2TextSpan> nameSpans;
  final bool cheats;
  final int flags;
  final int levelTimeTics;
  final String name;
  final String mapName;
  final String mapTitle;

  /// Название карты с цветами SRB2 (пусто — без цветов, см. [mapTitle]).
  final List<Srb2TextSpan> mapTitleSpans;
  final int actNum;
  final bool isZone;
  final String httpSource;
  final List<ServerFile> files;

  /// Средний уровень силы игроков (Ring Racers); null — нет или выключен.
  final int? avgPowerLevel;

  const ServerInfo({
    this.protocol = NetProtocol.srb2,
    this.avgPowerLevel,
    required this.packetVersion,
    required this.application,
    required this.version,
    required this.subversion,
    required this.players,
    required this.maxPlayers,
    required this.refuseReason,
    required this.gametype,
    required this.modified,
    required this.cheats,
    required this.flags,
    required this.levelTimeTics,
    required this.nameSpans,
    required this.name,
    required this.mapName,
    required this.mapTitle,
    this.mapTitleSpans = const [],
    required this.actNum,
    required this.isZone,
    required this.httpSource,
    required this.files,
  });

  String get versionString => protocol.formatVersion(version, subversion);
  bool get isDedicated => flags & Srb2Protocol.svDedicated != 0;

  /// Аддонов больше, чем влезло в пакет — остальные запрашиваются отдельно.
  bool get hasMoreFiles => flags & Srb2Protocol.svLotsOfAddons != 0;

  /// Та же игра и версия, что у поддерживаемой сборки — к серверу можно подключиться.
  bool get isCompatible =>
      version == protocol.version &&
      subversion == protocol.subversion &&
      application.toLowerCase() == protocol.application.toLowerCase();

  /// Скорость (Gear) в Ring Racers: 0–2 из kartvars.
  int get kartSpeed => flags & 0x03;

  /// "GREENFLOWER ZONE 1" (как в списке серверов игры).
  String get fullMapTitle {
    final title = mapTitle.isEmpty ? mapName : mapTitle;
    final zone = isZone ? ' ZONE' : '';
    final act = actNum > 0 ? ' $actNum' : '';
    return '$title$zone$act';
  }

  /// [fullMapTitle] с цветами SRB2.
  List<Srb2TextSpan> get fullMapTitleSpans {
    final zone = isZone ? ' ZONE' : '';
    final act = actNum > 0 ? ' $actNum' : '';
    final title = mapTitle.isEmpty
        ? [Srb2TextSpan(mapName, 0)]
        : mapTitleSpans.isEmpty
            ? [Srb2TextSpan(mapTitle, 0)]
            : mapTitleSpans;
    return [...title, if ('$zone$act'.isNotEmpty) Srb2TextSpan('$zone$act', 0)];
  }

  String get refuseText => switch (refuseReason) {
        -1 => 'Unknown',
        0 => 'Joinable',
        1 => 'Joins disabled',
        2 => 'Server full',
        3 => 'You are banned',
        _ => 'Refuses joins ($refuseReason)',
      };

  ServerInfo withFiles(List<ServerFile> all) => ServerInfo(
        protocol: protocol,
        avgPowerLevel: avgPowerLevel,
        packetVersion: packetVersion,
        application: application,
        version: version,
        subversion: subversion,
        players: players,
        maxPlayers: maxPlayers,
        refuseReason: refuseReason,
        gametype: gametype,
        modified: modified,
        cheats: cheats,
        flags: flags,
        levelTimeTics: levelTimeTics,
        nameSpans: nameSpans,
        name: name,
        mapName: mapName,
        mapTitle: mapTitle,
        mapTitleSpans: mapTitleSpans,
        actNum: actNum,
        isZone: isZone,
        httpSource: httpSource,
        files: all,
      );
}

/// Продолжение списка аддонов (PT_MOREFILESNEEDED).
class MoreFiles {
  final int first;
  final bool more;
  final List<ServerFile> files;
  const MoreFiles(this.first, this.more, this.files);
}

/// Сборка и разбор UDP-пакетов SRB2 (doomdata_t).
class Srb2Codec {
  Srb2Codec._();

  /// NetbufferChecksum: сумма байтов после поля checksum, умноженных на позицию.
  static int checksum(Uint8List packet) {
    var c = 0x1234567;
    for (var i = 4; i < packet.length; i++) {
      c = (c + packet[i] * (i - 3)) & 0xFFFFFFFF;
    }
    return c;
  }

  /// [ackReturn] — номер последнего подряд полученного "надёжного" пакета
  /// (поле ackreturn заголовка; нужно для старой передачи файлов SRB2Kart).
  static Uint8List buildPacket(int type, List<int> payload, {int ackReturn = 0}) {
    final b = Uint8List(Srb2Protocol.headerSize + payload.length);
    b[5] = ackReturn & 0xFF;
    b[6] = type;
    b.setRange(Srb2Protocol.headerSize, b.length, payload);
    ByteData.sublistView(b).setUint32(0, checksum(b), Endian.little);
    return b;
  }

  static List<int> _u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  /// PT_ASKINFO: askinfo_pak { UINT8 version; tic_t time }.
  static Uint8List askInfo(int time, [NetProtocol proto = NetProtocol.srb2]) =>
      buildPacket(proto.ptAskInfo, [proto.version, ..._u32(time)]);

  /// PT_TELLFILESNEEDED: "пришли список аддонов начиная с [first]".
  static Uint8List tellFilesNeeded(int first, [NetProtocol proto = NetProtocol.srb2]) =>
      buildPacket(proto.ptTellFilesNeeded, _u32(first));

  /// Тип пакета или null, если пакет повреждён (длина/контрольная сумма).
  static int? packetType(Uint8List p) {
    if (p.length < Srb2Protocol.headerSize) return null;
    final sum = ByteData.sublistView(p).getUint32(0, Endian.little);
    if (sum != checksum(p)) return null;
    return p[6];
  }

  /// Строка C фиксированной длины без цветовых кодов и символов вне шрифта SRB2.
  static String cString(Uint8List b, int offset, int maxLength) =>
      Srb2Text.plain(cSpans(b, offset, maxLength));

  /// То же с цветами SRB2.
  static List<Srb2TextSpan> cSpans(Uint8List b, int offset, int maxLength) {
    final end = offset + maxLength < b.length ? offset + maxLength : b.length;
    return Srb2Text.parse(Uint8List.sublistView(b, offset, end));
  }

  static String _hex(Uint8List b, int offset, int length) {
    final out = StringBuffer();
    for (var i = offset; i < offset + length; i++) {
      out.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// Записи списка аддонов (PutFileNeeded): status, [folder], size, name\0, md5[16].
  /// Байт folder есть только у SRB2.
  static List<ServerFile> parseFiles(Uint8List b, int offset, int count,
      [NetProtocol proto = NetProtocol.srb2]) {
    final files = <ServerFile>[];
    final head = proto.fileEntryHasFolder ? 6 : 5;
    var p = offset;
    for (var i = 0; i < count; i++) {
      if (p + head > b.length) break;
      final status = b[p];
      final folder = proto.fileEntryHasFolder && b[p + 1] != 0;
      final size = ByteData.sublistView(b).getUint32(p + head - 4, Endian.little);
      p += head;
      var end = p;
      while (end < b.length && b[end] != 0) {
        end++;
      }
      final name = String.fromCharCodes(b, p, end);
      p = end + 1;
      if (p + 16 > b.length) break;
      final md5 = _hex(b, p, 16);
      p += 16;
      final send = proto.willSend(status >> 4);
      files.add(ServerFile(name: name, size: size, md5: md5, willSend: send, isFolder: folder));
    }
    return files;
  }

  /// PT_SERVERINFO → [ServerInfo]; null для чужого/старого формата.
  static ServerInfo? parseServerInfo(Uint8List p, [NetProtocol proto = NetProtocol.srb2]) {
    const o = Srb2Protocol.headerSize;
    if (p.length < o + proto.offFileNeeded) return null;
    
    // Проверка заголовка в зависимости от поддержки префикса
    if (proto.hasPacketVersionPrefix) {
      if (p[o] != 255 || p[o + 1] != proto.packetVersion) return null;
    } else {
      if (p[o] != proto.version) return null;
    }

    final data = ByteData.sublistView(p);
    final nameSpans = cSpans(p, o + proto.offServerName, 32);
    final pwr = proto.offAvgPowerLevel == null ? null : data.getInt16(o + proto.offAvgPowerLevel!, Endian.little);
    
    return ServerInfo(
      protocol: proto,
      packetVersion: proto.hasPacketVersionPrefix ? p[o + 1] : proto.packetVersion,
      application: proto.hasPacketVersionPrefix ? cString(p, o + proto.offApplication, 16) : proto.application,
      version: p[o + proto.offVersion],
      subversion: p[o + proto.offVersion + 1],
      players: p[o + proto.offPlayers],
      maxPlayers: p[o + proto.offPlayers + 1],
      refuseReason: proto.offRefuseReason == null ? -1 : p[o + proto.offRefuseReason!],
      gametype: proto.gametypeNames == null
          ? cString(p, o + proto.offGametype, 24)
          : proto.gametypeNames![p[o + proto.offGametype]] ?? 'Gametype ${p[o + proto.offGametype]}',
      modified: p[o + proto.offModified] != 0,
      cheats: p[o + proto.offModified + 1] != 0,
      flags: p[o + proto.offFlags],
      levelTimeTics: data.getUint32(o + proto.offLevelTime, Endian.little),
      nameSpans: nameSpans,
      name: Srb2Text.plain(nameSpans),
      mapName: proto.offMapName == null ? '' : cString(p, o + proto.offMapName!, 8),
      mapTitle: cString(p, o + proto.offMapTitle, 33),
      mapTitleSpans: cSpans(p, o + proto.offMapTitle, 33),
      actNum: p[o + proto.offActNum],
      isZone: p[o + proto.offIsZone] != 0,
      httpSource: proto.offHttpSource == null ? '' : cString(p, o + proto.offHttpSource!, 256),
      avgPowerLevel: pwr == null || pwr < 0 ? null : pwr,
      files: parseFiles(p, o + proto.offFileNeeded, p[o + proto.offFileCount], proto),
    );
  }

  /// PT_PLAYERINFO → игроки (пустые слоты пропускаются).
  static List<ServerPlayer> parsePlayerInfo(Uint8List p, [NetProtocol proto = NetProtocol.srb2]) {
    const o = Srb2Protocol.headerSize;
    final data = ByteData.sublistView(p);
    final players = <ServerPlayer>[];
    for (var i = 0; i < Srb2Protocol.maxPlayers; i++) {
      final s = o + i * Srb2Protocol.playerInfoSize;
      if (s + Srb2Protocol.playerInfoSize > p.length) break;
      if (p[s] == 255) continue; // пустой слот
      players.add(ServerPlayer(
        num: p[s],
        name: cString(p, s + 1, 22),
        team: p[s + 27],
        skin: p[s + 28],
        score: data.getUint32(s + 30, Endian.little),
        secondsInServer: data.getUint16(s + 34, Endian.little),
        baseSkins: proto.baseSkins,
      ));
    }
    return players;
  }

  /// PT_MOREFILESNEEDED: { INT32 first; UINT8 num; UINT8 more; files[] }.
  static MoreFiles? parseMoreFiles(Uint8List p, [NetProtocol proto = NetProtocol.srb2]) {
    const o = Srb2Protocol.headerSize;
    if (p.length < o + 6) return null;
    final first = ByteData.sublistView(p).getInt32(o, Endian.little);
    return MoreFiles(first, p[o + 5] != 0, parseFiles(p, o + 6, p[o + 4], proto));
  }
}

/// Сервер из списка мастер-сервера.
class MasterServerEntry {
  final String host;
  final int port;

  /// Имя как прислал мастер-сервер: байты (по символу на байт) с кодами цвета SRB2.
  final String title;
  final String version;
  final int room;

  /// Контакт владельца (мастер-сервер Ring Racers); у SRB2 пусто.
  final String contact;

  const MasterServerEntry({
    required this.host,
    required this.port,
    required this.title,
    required this.version,
    required this.room,
    this.contact = '',
  });

  List<Srb2TextSpan> get titleSpans => Srb2Text.parse(title.codeUnits);

  MasterServerEntry withTitle(String newTitle) => MasterServerEntry(
        host: host,
        port: port,
        title: newTitle,
        version: version,
        room: room,
        contact: contact,
      );
  String get plainTitle => Srb2Text.plain(titleSpans);

  Map<String, dynamic> toJson() =>
      {'host': host, 'port': port, 'title': title, 'version': version, 'room': room, if (contact.isNotEmpty) 'contact': contact};

  static MasterServerEntry? fromJson(dynamic j) {
    if (j is! Map || j['host'] is! String || j['port'] is! int) return null;
    return MasterServerEntry(
      host: j['host'] as String,
      port: j['port'] as int,
      title: j['title'] is String ? j['title'] as String : '',
      version: j['version'] is String ? j['version'] as String : '',
      room: j['room'] is int ? j['room'] as int : 0,
      contact: j['contact'] is String ? j['contact'] as String : '',
    );
  }
}

/// Разбор ответов HTTP API мастер-сервера (src/netcode/http-mserv.c).
class MasterServerParser {
  MasterServerParser._();

  /// %XX → байты; хранится по символу на байт, цвета разбираются при показе.
  static String _decodeTitle(String raw) => String.fromCharCodes(Srb2Text.percentDecode(raw));

  /// GET <ms>/servers: блоки по комнатам через пустую строку,
  /// первая строка блока — номер комнаты, дальше "адрес порт имя версия".
  static List<MasterServerEntry> parseServers(String body) {
    final result = <MasterServerEntry>[];
    final text = body.replaceAll('\r\n', '\n');
    for (final section in text.split('\n\n')) {
      final lines = section.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.length < 2) continue;
      final room = int.tryParse(lines.first.trim());
      if (room == null) continue;
      for (final line in lines.skip(1)) {
        final parts = line.trim().split(' ');
        if (parts.length < 4) continue;
        final port = int.tryParse(parts[1]);
        if (port == null || port <= 0 || port > 65535) continue;
        result.add(MasterServerEntry(
          host: parts[0],
          port: port,
          title: _decodeTitle(parts[2]),
          version: parts.sublist(3).join(' ').trim(),
          room: room,
        ));
      }
    }
    return result;
  }

  /// Ring Racers: GET <ms>/games/RingRacers/<MODVERSION>/servers — строки
  /// "адрес порт контакт" (src/http-mserv.c, HMS_fetch_servers). Имени и
  /// комнат нет: имя приходит при опросе сервера.
  static List<MasterServerEntry> parseKartServers(String body, {String version = ''}) {
    final result = <MasterServerEntry>[];
    for (final raw in body.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parts = line.split(' ');
      if (parts.length < 2) break; // как в игре: кривая строка — конец разбора
      final port = int.tryParse(parts[1]);
      if (port == null || port <= 0 || port > 65535) continue;
      result.add(MasterServerEntry(
        host: parts[0],
        port: port,
        title: '',
        version: version,
        room: 0,
        contact: parts.length > 2 ? parts.sublist(2).join(' ').trim() : '',
      ));
    }
    return result;
  }

  /// GET <ms>/rooms: блоки "id\nназвание\nописание" через две пустые строки.
  static Map<int, String> parseRooms(String body) {
    final rooms = <int, String>{};
    for (final section in body.replaceAll('\r\n', '\n').split('\n\n\n')) {
      final lines = section.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.length < 2) continue;
      final id = int.tryParse(lines[0].trim());
      if (id != null) rooms[id] = lines[1].trim();
    }
    return rooms;
  }
}

/// "host", "host:port", "[ipv6]:port" → (host, port).
(String, int)? parseServerAddress(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  s = s.replaceFirst(RegExp(r'^(srb2|ringracers|drrr)://', caseSensitive: false), '');
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);

  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return null;
    final host = s.substring(1, close);
    final rest = s.substring(close + 1);
    if (rest.isEmpty) return (host, Srb2Protocol.defaultPort);
    if (!rest.startsWith(':')) return null;
    final port = int.tryParse(rest.substring(1));
    return port == null || port <= 0 || port > 65535 ? null : (host, port);
  }

  final colons = ':'.allMatches(s).length;
  if (colons == 1) {
    final i = s.indexOf(':');
    final port = int.tryParse(s.substring(i + 1));
    if (port == null || port <= 0 || port > 65535 || i == 0) return null;
    return (s.substring(0, i), port);
  }
  // Без порта (или голый IPv6 без скобок).
  return (s, Srb2Protocol.defaultPort);
}
