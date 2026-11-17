import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n.dart';
import '../theme/app_themes.dart';

/// Выбор языка интерфейса (с флагами): загружает и запоминает выбранный.
class LanguageDropdown extends StatelessWidget {
  final VoidCallback? onChanged;
  const LanguageDropdown({super.key, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final i18n = I18n.instance;
    return DropdownButtonFormField<String>(
      // Ключ — язык: после смены поле строится заново с новым значением.
      key: ValueKey(i18n.code),
      initialValue: i18n.code,
      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
      items: [
        for (final l in i18n.available)
          DropdownMenuItem(
            value: l.code,
            child: Row(
              children: [
                // Флаг языка слева от названия (assets/flags); нет картинки — без него.
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Image.asset('assets/flags/${l.flag}.png',
                      width: 22, height: 16.5, fit: BoxFit.fill, errorBuilder: (_, _, _) => const SizedBox(width: 22)),
                ),
                const SizedBox(width: 10),
                Text(l.name),
              ],
            ),
          ),
      ],
      onChanged: (code) async {
        if (code == null) return;
        await i18n.load(code);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('app_language', code);
        onChanged?.call();
      },
    );
  }
}

/// Выбор цветовой темы.
class ThemeDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const ThemeDropdown({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
        initialValue: value,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        items: [
          for (final theme in AppThemes.availableThemes)
            DropdownMenuItem<String>(value: theme['key'] as String, child: Text(tr(theme['name'] as String))),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
}
