import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/server_blacklist.dart';

/// Settings → Servers: чёрный список (адреса и слова), общий для всех игр.
class BlacklistSettings extends StatefulWidget {
  const BlacklistSettings({super.key});

  @override
  State<BlacklistSettings> createState() => _BlacklistSettingsState();
}

class _BlacklistSettingsState extends State<BlacklistSettings> {
  final _address = TextEditingController();
  final _word = TextEditingController();
  final _list = ServerBlacklist.instance;

  @override
  void initState() {
    super.initState();
    _list.load();
  }

  @override
  void dispose() {
    _address.dispose();
    _word.dispose();
    super.dispose();
  }

  /// `ip` или `ip:port` (IPv6 с портом — в скобках).
  Future<void> _addAddress() async {
    final v = _address.text.trim();
    if (v.isEmpty) return;
    final m = RegExp(r'^\[(.+)\]:(\d+)$').firstMatch(v) ?? RegExp(r'^([^:]+):(\d+)$').firstMatch(v);
    if (m != null) {
      await _list.addAddress(m[1]!, int.parse(m[2]!));
    } else {
      await _list.addAddress(v.replaceAll(RegExp(r'^\[|\]$'), ''));
    }
    _address.clear();
  }

  Future<void> _addWord() async {
    await _list.addWord(_word.text);
    _word.clear();
  }

  Widget _chips(List<String> items, Future<void> Function(String) remove) => items.isEmpty
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(tr('Empty'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
        )
      : Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final x in items)
              InputChip(
                label: Text(x),
                onDeleted: () => remove(x),
                deleteButtonTooltipMessage: tr('Remove from the blacklist'),
              ),
          ],
        );

  Widget _field(TextEditingController c, String hint, VoidCallback add) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: c,
              onSubmitted: (_) => add(),
              decoration: InputDecoration(hintText: hint, isDense: true, border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: add, child: Text(tr('Add'))),
        ],
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _list,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Addresses'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            _chips(_list.addresses, _list.removeAddress),
            const SizedBox(height: 6),
            _field(_address, tr('IP (all its servers) or IP:port'), _addAddress),
            const SizedBox(height: 14),
            Text(tr('Words in the server name'), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            _chips(_list.words, _list.removeWord),
            const SizedBox(height: 6),
            _field(_word, tr('A word or part of it'), _addWord),
          ],
        ),
      );
}
