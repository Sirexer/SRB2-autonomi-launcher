import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/launch_settings.dart';
import '../services/launch_state.dart';

/// Составная кнопка запуска: основная часть запускает со сборкой по умолчанию,
/// правая стрелка открывает меню выбора конкретной сборки (как на вкладке Servers).
class BuildSplitButton extends StatelessWidget {
  final LaunchSettings launch;
  final String label;
  final String? buttonTooltip;
  final String? menuTooltip;
  final bool enabled;
  final bool busy;
  final double height;
  final double horizontalPadding;
  final double dropdownWidth;
  final double? fontSize;
  final Color color;
  final Color dividerColor;
  final void Function(String? executableId) onPressed;

  const BuildSplitButton({
    super.key,
    required this.launch,
    required this.label,
    required this.onPressed,
    this.buttonTooltip,
    this.menuTooltip,
    this.enabled = true,
    this.busy = false,
    this.height = 44,
    this.horizontalPadding = 22,
    this.dropdownWidth = 38,
    this.fontSize,
    this.color = Colors.green,
    this.dividerColor = const Color(0xFF1B5E20),
  });

  @override
  Widget build(BuildContext context) {
    final radius = height / 2;
    return SizedBox(
      height: height,
      child: ValueListenableBuilder<bool>(
        valueListenable: launchPreparing,
        builder: (context, preparing, _) {
          final spinning = busy || preparing;
          final canLaunch = enabled && !spinning;
          final leftButton = ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.horizontal(left: Radius.circular(radius)),
              ),
            ),
            icon: spinning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Icon(Icons.play_arrow, size: height < 40 ? 18 : 20),
            label: Text(
              preparing ? tr('Checking...') : label,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: fontSize),
            ),
            onPressed: canLaunch ? () => onPressed(null) : null,
          );
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (buttonTooltip != null)
                Tooltip(message: buttonTooltip!, child: leftButton)
              else
                leftButton,
              ListenableBuilder(
                listenable: launch,
                builder: (context, _) {
                  final menuEnabled = enabled && !busy && launch.executables.isNotEmpty;
                  return PopupMenuButton<String>(
                    tooltip: menuTooltip ?? tr('Play with another build'),
                    enabled: menuEnabled,
                    onSelected: (id) => onPressed(id),
                    itemBuilder: (context) => [
                      for (final e in launch.executables)
                        PopupMenuItem(
                          value: e.id,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              launch.isDefault(e) ? Icons.star : Icons.terminal,
                              size: 18,
                              color: launch.isDefault(e) ? Colors.amber : null,
                            ),
                            title: Text(e.name),
                            subtitle: Text(
                              e.command,
                              style: const TextStyle(fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                    ],
                    child: Container(
                      width: dropdownWidth,
                      decoration: BoxDecoration(
                        color: menuEnabled ? color : color.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.horizontal(right: Radius.circular(radius)),
                        border: Border(left: BorderSide(color: dividerColor, width: 1)),
                      ),
                      child: const Icon(Icons.arrow_drop_down, color: Colors.white),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
