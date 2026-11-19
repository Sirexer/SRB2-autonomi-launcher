import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Чёрный список серверов (общий для всех игр): такие серверы не
/// показываются в списке. Мои серверы (избранные) показываются всегда.
/// - адрес: `ip` — все серверы на этом адресе, `ip:port` — один сервер;
/// - слово: сервер, в имени которого оно есть (без учёта регистра и цветов).
class ServerBlacklist extends ChangeNotifier {
  ServerBlacklist._();
  static final instance = ServerBlacklist._();

  static const _kAddresses = 'servers_blacklist_addresses';
  static const _kWords = 'servers_blacklist_words';

  final List<String> addresses = [];
  final List<String> words = [];
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    addresses
      ..clear()
      ..addAll(prefs.getStringList(_kAddresses) ?? const []);
    words
      ..clear()
      ..addAll(prefs.getStringList(_kWords) ?? const []);
    _loaded = true;
    notifyListeners();
  }

  /// Ключ адреса: хост в нижнем регистре, с портом или без.
  static String addressKey(String host, [int? port]) {
    final h = host.trim().toLowerCase();
    if (port == null) return h;
    return h.contains(':') ? '[$h]:$port' : '$h:$port';
  }

  /// Сервер [host]:[port] в списке по адресу (весь хост или этот порт).
  bool blocksAddress(String host, int port) =>
      addresses.contains(addressKey(host)) || addresses.contains(addressKey(host, port));

  /// Слово из списка, которое есть в имени [name]; null — нет.
  String? wordIn(String name) {
    final n = name.toLowerCase();
    for (final w in words) {
      if (w.isNotEmpty && n.contains(w.toLowerCase())) return w;
    }
    return null;
  }

  bool blocks(String host, int port, String name) => blocksAddress(host, port) || wordIn(name) != null;

  Future<void> addAddress(String host, [int? port]) async {
    final key = addressKey(host, port);
    if (key.isEmpty || addresses.contains(key)) return;
    addresses.add(key);
    await _save();
  }

  Future<void> addWord(String word) async {
    final w = word.trim();
    if (w.isEmpty || words.any((x) => x.toLowerCase() == w.toLowerCase())) return;
    words.add(w);
    await _save();
  }

  Future<void> removeAddress(String key) async {
    addresses.remove(key);
    await _save();
  }

  Future<void> removeWord(String word) async {
    words.remove(word);
    await _save();
  }

  Future<void> _save() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kAddresses, addresses);
    await prefs.setStringList(_kWords, words);
  }
}
