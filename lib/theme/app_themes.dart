import 'package:flutter/material.dart';

class AppThemes {
  static const String deepOrange = 'deepOrange';
  static const String blue = 'blue';
  static const String green = 'green';
  static const String purple = 'purple';

  // Добавляем список доступных тем для выпадающего списка в настройках
  static const List availableThemes = [
    {'key': deepOrange, 'name': 'Deep Orange'},
    {'key': blue, 'name': 'Cyber Blue'},
    {'key': green, 'name': 'Emerald Green'},
    {'key': purple, 'name': 'Purple Night'},
  ];

  static MaterialColor getThemeColor(String key) {
    switch (key) {
      case blue:
        return Colors.blue;
      case green:
        return Colors.green;
      case purple:
        return Colors.purple;
      case deepOrange:
      default:
        return Colors.deepOrange;
    }
  }

  static ThemeData getThemeData(String key) {
    return ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: getThemeColor(key),
        brightness: Brightness.dark,
      ),
      // Уведомления — всплывающие карточки с крестиком, а не полоса внизу окна.
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        width: 560,
        showCloseIcon: true,
      ),
    );
  }

  static Widget buildThemeSelectorDialog(BuildContext context, String currentKey, ValueChanged<String> onSelected) {
    return AlertDialog(
      title: const Text('Select Color Theme'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const CircleAvatar(backgroundColor: Colors.deepOrange),
            title: const Text('Deep Orange'),
            trailing: currentKey == deepOrange ? const Icon(Icons.check, color: Colors.deepOrange) : null,
            onTap: () {
              onSelected(deepOrange);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const CircleAvatar(backgroundColor: Colors.blue),
            title: const Text('Cyber Blue'),
            trailing: currentKey == blue ? const Icon(Icons.check, color: Colors.blue) : null,
            onTap: () {
              onSelected(blue);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const CircleAvatar(backgroundColor: Colors.green),
            title: const Text('Emerald Green'),
            trailing: currentKey == green ? const Icon(Icons.check, color: Colors.green) : null,
            onTap: () {
              onSelected(green);
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const CircleAvatar(backgroundColor: Colors.purple),
            title: const Text('Purple Night'),
            trailing: currentKey == purple ? const Icon(Icons.check, color: Colors.purple) : null,
            onTap: () {
              onSelected(purple);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}