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

/// Образец темы: фон с кружком акцента.
class ThemeSwatch extends StatelessWidget {
  final LauncherTheme theme;
  final double size;
  const ThemeSwatch(this.theme, {super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    final bg = theme.background ?? (theme.dark ? const Color(0xFF141218) : scheme.surface);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.grey.withValues(alpha: 0.6)),
      ),
      alignment: Alignment.center,
      child: Container(
        width: size * 0.55,
        height: size * 0.55,
        decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
      ),
    );
  }
}

/// Название темы: у встроенных — переведённое.
String themeName(LauncherTheme t) => t.path == null ? tr(t.name) : t.name;

/// Выбор цветовой темы.
class ThemeDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const ThemeDropdown({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final themes = AppThemes.all;
    return DropdownButtonFormField<String>(
      // Новые/удалённые темы — поле заново.
      key: ValueKey('${themes.length}:$value'),
      initialValue: themes.any((t) => t.key == value) ? value : themes.first.key,
      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
      items: [
        for (final t in themes)
          DropdownMenuItem<String>(
            value: t.key,
            child: Row(
              children: [
                ThemeSwatch(t),
                const SizedBox(width: 10),
                Flexible(child: Text(themeName(t), overflow: TextOverflow.ellipsis)),
                if (t.editable) ...[
                  const SizedBox(width: 8),
                  Text(tr('(yours)'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ],
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
