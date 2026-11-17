import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';
import 'platform_utils.dart';

/// Chunk progress that the daemon writes to its log: `Downloaded 3/5`.
class ChunkProgress {
  final String requestId;
  final int done;
  final int total;
  const ChunkProgress(this.requestId, this.done, this.total);
}

/// Manages the antd daemon (REST on 127.0.0.1:8082) that antd_client talks to.
class AntdDaemon {
  static final _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');
  static final _chunkRe = RegExp(r'Downloaded\s+(\d+)\s*/\s*(\d+)');
  static final _reqRe = RegExp(r'request_id=([0-9A-Za-z-]+)');
  static final StreamController<ChunkProgress> _chunkCtrl =
      StreamController<ChunkProgress>.broadcast();

  /// Chunk progress. Only works if the daemon was started by the launcher
  /// (we read its log); an externally started daemon emits no events.
  static Stream<ChunkProgress> get chunkProgress => _chunkCtrl.stream;

  static void _onLogLine(String raw, {bool isErr = false}) {
    final line = raw.replaceAll(_ansi, '');
    // Журнал демона — только в консоль (его много: ход каждой загрузки).
    AppLog.console('[antd] $line', file: false);
    final m = _chunkRe.firstMatch(line);
    if (m == null) return;
    final done = int.tryParse(m.group(1)!);
    final total = int.tryParse(m.group(2)!);
    if (done == null || total == null) return;
    final req = _reqRe.firstMatch(line)?.group(1) ?? '';
    _chunkCtrl.add(ChunkProgress(req, done, total));
  }

  static Process? _proc;
  static const _host = '127.0.0.1';
  static const _port = 8082;
  static const baseUrl = 'http://$_host:$_port';

  // ant-sdk release tag. Check the repository's Releases page for newer versions.
  static const _version = 'v0.17.0';

  /// Where the release is downloaded from, in order: GitHub, then the
  /// official GitLab mirror (gitlab.com/autonomi/ant-sdk, project 88885118;
  /// same file names). The next one is tried when a download or its SHA256
  /// check fails (on 2026-11-12 the GitHub repository answered 404).
  static const _sources = [
    'https://github.com/WithAutonomi/ant-sdk/releases/download/$_version',
    'https://gitlab.com/api/v4/projects/88885118/packages/generic/ant-sdk/$_version',
  ];

  // Asset names as published by ant-sdk's release workflow
  // (linux amd64/arm64, windows amd64, macOS arm64).
  static String get _asset {
    final asset = PlatformUtils.antdAssetName();
    if (asset == null) {
      throw UnsupportedError(
          'No antd build for this platform. Start antd manually on $_host:$_port.');
    }
    return asset;
  }

  /// TCP check (does not depend on the health endpoint path).
  static Future<bool> _isUp() async {
    try {
      final s = await Socket.connect(_host, _port,
          timeout: const Duration(seconds: 1));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String get _binaryName => Platform.isWindows ? 'antd.exe' : 'antd';

  /// The binary lives in a per-version folder, so bumping [_version]
  /// actually downloads the new daemon instead of reusing the old one.
  static Future<File> _binary() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'antd', _version, _binaryName));
  }

  /// Removes the binary of older launcher versions (stored without a version folder).
  static Future<void> _removeLegacyBinary() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final legacy = File(p.join(dir.path, 'antd', _binaryName));
      if (await legacy.exists()) await legacy.delete();
    } catch (_) {}
  }

  static Future<String> _fetchText(String url) async {
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(Uri.parse(url))).close();
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: $url');
      return await r.transform(const SystemEncoding().decoder).join();
    } finally {
      c.close();
    }
  }

  static Future<void> _download(String url, File dest) async {
    await dest.parent.create(recursive: true);
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(Uri.parse(url))).close();
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}: $url');
      final sink = dest.openWrite();
      await r.pipe(sink);
    } finally {
      c.close();
    }
  }

  /// antd that came with the launcher build (folder `antd` next to the
  /// launcher: the Windows zip, the AppImage), if it is the version the
  /// launcher expects (file VERSION); null — none, download it.
  static File? _bundledBinary() {
    try {
      final dir = p.join(p.dirname(Platform.resolvedExecutable), 'antd');
      final bin = File(p.join(dir, _binaryName));
      final version = File(p.join(dir, 'VERSION'));
      if (!bin.existsSync() || !version.existsSync()) return null;
      return version.readAsStringSync().trim() == _version ? bin : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _ensureBinary(File bin) async {
    if (await bin.exists()) return;

    final tmp = File('${bin.path}.part');
    final bundled = _bundledBinary();
    if (bundled != null) {
      // Copied into the data folder rather than started in place: the
      // AppImage is mounted at a new path every time, and the launcher finds
      // its own (stuck) daemons by the data folder.
      await bin.parent.create(recursive: true);
      await bundled.copy(tmp.path);
      await tmp.rename(bin.path);
      if (!Platform.isWindows) await Process.run('chmod', ['755', bin.path]);
      await _removeLegacyBinary();
      AppLog.console('[antd] using the antd that came with the launcher');
      return;
    }

    Object? error;
    for (final base in _sources) {
      try {
        await _downloadVerified(base, tmp);
        error = null;
        break;
      } catch (e) {
        error = e;
        AppLog.console('[antd] download from ${Uri.parse(base).host} failed: $e');
        if (await tmp.exists()) await tmp.delete();
      }
    }
    if (error != null) throw error;

    await tmp.rename(bin.path);
    if (!Platform.isWindows) await Process.run('chmod', ['755', bin.path]);
    await _removeLegacyBinary();
  }

  /// Downloads the antd binary of the release at [base] into [tmp] and
  /// checks it against SHA256SUMS of the same release.
  static Future<void> _downloadVerified(String base, File tmp) async {
    await _download('$base/$_asset', tmp);
    final sums = await _fetchText('$base/SHA256SUMS');
    final line = sums.split('\n').firstWhere(
          (l) => l.contains(_asset),
          orElse: () => throw Exception('$_asset not found in SHA256SUMS'),
        );
    final expected = line.trim().split(RegExp(r'\s+')).first.toLowerCase();
    final actual = (await sha256.bind(tmp.openRead()).first).toString();
    if (actual != expected) throw Exception('SHA256 mismatch for $_asset');
  }

  static Future<bool>? _starting;

  /// Makes sure the daemon is listening on the port. true = downloads can proceed.
  /// Concurrent calls share a single startup (no second process is spawned).
  static Future<bool> ensureRunning() =>
      _starting ??= _ensureRunning().whenComplete(() => _starting = null);

  static Future<bool> _ensureRunning() async {
    if (await _isUp()) {
      // Already running (e.g. the user runs their own antd): use it — if it
      // really answers. A daemon left over from a previous launcher session
      // may hold the port but hang; ours (in the launcher's data folder) is
      // then killed and started again.
      if (await _responds()) return true;
      AppLog.console('[antd] the daemon on port $_port does not answer, restarting it');
      if (!await _killOwnDaemons()) return false; // someone else's antd: leave it
      await _waitPortFree();
    }

    try {
      final bin = await _binary();
      await _ensureBinary(bin);
      AppLog.console('[antd] starting ${bin.path}');

      final proc = await Process.start(
        bin.path,
        [],
        // environment: {'ANTD_PEERS': '...'}, // if peers are needed to connect
      );
      _proc = proc;
      proc.exitCode.then((_) {
        if (identical(_proc, proc)) _proc = null;
      });

      // Print daemon logs to the console (also keeps the pipes from filling up).
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) => _onLogLine(l));
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((l) => _onLogLine(l, isErr: true));

      int? exitCode;
      proc.exitCode.then((c) => exitCode = c);

      for (var i = 0; i < 60; i++) {
        if (await _isUp()) return true;
        if (exitCode != null) {
          AppLog.console('antd start error: process exited with code $exitCode');
          _proc = null;
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      AppLog.console('antd start error: port $_port did not open within 30 s (process is still alive)');
    } catch (e) {
      AppLog.console('antd start error: $e');
    }
    return false;
  }

  static void stop() {
    _proc?.kill();
    _proc = null;
  }

  /// Останавливает наш демон совсем (перед обновлением лаунчера: новая
  /// версия запустит свой).
  static Future<void> shutdown() async {
    _proc?.kill();
    _proc = null;
    try {
      await _killOwnDaemons();
    } catch (_) {}
  }

  // --- Restarting a stuck daemon ---

  static final StreamController<void> _restartedCtrl = StreamController<void>.broadcast();

  /// The daemon was restarted (the launcher retries what failed: icons...).
  static Stream<void> get restarted => _restartedCtrl.stream;

  static DateTime? _lastRestart;

  /// Restarts our daemon: stops it (also one left over from a previous
  /// session) and starts it again. Not more often than once a minute unless
  /// [force] (the button in Settings).
  static Future<bool> restart({bool force = false}) async {
    final last = _lastRestart;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(minutes: 1)) return false;
    _lastRestart = DateTime.now();
    await (_starting ?? Future<bool>.value(true));
    AppLog.console('[antd] restarting');
    _proc?.kill();
    _proc = null;
    await _killOwnDaemons();
    await _waitPortFree();
    final ok = await ensureRunning();
    if (ok) _restartedCtrl.add(null);
    return ok;
  }

  /// Does the daemon answer HTTP? Any response counts; a stuck daemon keeps
  /// the port open but does not answer.
  static Future<bool> _responds() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await c.getUrl(Uri.parse('$baseUrl/health')).timeout(const Duration(seconds: 3));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>().timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  static Future<void> _waitPortFree() async {
    for (var i = 0; i < 20 && await _isUp(); i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Kills antd processes started from the launcher's data folder (any
  /// version), found by the executable path. true — at least one was found;
  /// false — the daemon on the port is not ours.
  static Future<bool> _killOwnDaemons() async {
    final dir = p.join((await getApplicationSupportDirectory()).path, 'antd');
    var found = false;
    try {
      if (Platform.isWindows) {
        // Processes named antd.exe whose path is inside our folder.
        final script = "Get-CimInstance Win32_Process -Filter \"Name='$_binaryName'\" | "
            "Where-Object { \$_.ExecutablePath -and \$_.ExecutablePath.StartsWith('${dir.replaceAll("'", "''")}', "
            "[System.StringComparison]::OrdinalIgnoreCase) } | "
            "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force; \$_.ProcessId }";
        final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script])
            .timeout(const Duration(seconds: 15));
        found = '${r.stdout}'.trim().isNotEmpty;
      } else {
        for (final e in Directory('/proc').listSync()) {
          final pid = int.tryParse(p.basename(e.path));
          if (pid == null) continue;
          try {
            final exe = Link(p.join(e.path, 'exe')).targetSync();
            if (p.isWithin(dir, exe)) {
              Process.killPid(pid, ProcessSignal.sigkill);
              found = true;
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      AppLog.console('[antd] cannot stop the old daemon: $e');
    }
    return found;
  }
}
