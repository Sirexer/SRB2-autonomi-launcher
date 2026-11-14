import '../services/app_log.dart';
import '../i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import '../services/autonomi_service.dart';
import '../services/antd_daemon.dart';
import 'snack.dart';

class AddManifestDialog extends StatefulWidget {
  /// «Автоматически добавлять рекомендуемые к сокрытию теги» — та же
  /// настройка, что в Settings → Addons (меняется вместе с ней).
  final bool autoHideTags;
  final ValueChanged<bool> onAutoHideTagsChanged;

  /// Pointer, уже вставленный в поле (из pointer.txt), и пояснение над ним.
  final String? initialPointer;
  final String? intro;

  const AddManifestDialog({
    super.key,
    required this.autoHideTags,
    required this.onAutoHideTagsChanged,
    this.initialPointer,
    this.intro,
  });

  @override
  State<AddManifestDialog> createState() => _AddManifestDialogState();
}

class _AddManifestDialogState extends State<AddManifestDialog> {
  final _inputController = TextEditingController();
  int _mode = 0; // 0 - Autonomi Hash, 1 - JSON Text, 2 - PC JSON File
  bool _isLoading = false;
  String? _droppedFilePath;
  bool _isDraggingOver = false;
  late bool _autoHideTags = widget.autoHideTags;

  @override
  void initState() {
    super.initState();
    if (widget.initialPointer != null) _inputController.text = widget.initialPointer!;
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _pickJsonFile() async {
    AppLog.action('open the openFile dialog (add_manifest_dialog.dart)');
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr('JSON'), extensions: ['json', 'JSON']),
      ],
      confirmButtonText: tr('Open'),
    );
    if (file != null && mounted) {
      setState(() => _droppedFilePath = file.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return AlertDialog(
      title: Text(tr('Connect Addon Repository')),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.intro != null) ...[
              Text(widget.intro!),
              const SizedBox(height: 16),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text(tr('Autonomi Hash')),
                    selected: _mode == 0,
                    onSelected: _isLoading ? null : (val) => setState(() { _mode = 0; _inputController.clear(); _droppedFilePath = null; }),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(tr('JSON Text')),
                    selected: _mode == 1,
                    onSelected: _isLoading ? null : (val) => setState(() { _mode = 1; _inputController.clear(); _droppedFilePath = null; }),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(tr('PC JSON File')),
                    selected: _mode == 2,
                    onSelected: _isLoading ? null : (val) => setState(() { _mode = 2; _inputController.clear(); }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_mode == 2)
              DropTarget(
                onDragDone: (details) {
                  if (details.files.isNotEmpty) {
                    final filePath = details.files.first.path;
                    if (filePath.toLowerCase().endsWith('.json')) {
                      setState(() {
                        _droppedFilePath = filePath;
                      });
                    } else {
                      showSnack(context, 
                        SnackBar(content: Text(tr('Please drop a valid .json file!')), backgroundColor: Colors.orange),
                      );
                    }
                  }
                },
                onDragEntered: (details) => setState(() => _isDraggingOver = true),
                onDragExited: (details) => setState(() => _isDraggingOver = false),
                child: InkWell(
                  onTap: _isLoading ? null : _pickJsonFile,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    height: 120,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _isDraggingOver ? primary.withValues(alpha: 0.2) : Colors.black26,
                      border: Border.all(
                        color: _isDraggingOver ? primary : Colors.grey[700]!,
                        width: 2,
                        style: BorderStyle.solid,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Text(
                        _droppedFilePath != null
                            ? tr('Selected file:\n{path}\n(click to choose another)', {'path': _droppedFilePath})
                            : tr('Drag & Drop a .json repository file here\nor click to browse'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _droppedFilePath != null ? Colors.greenAccent : Colors.grey,
                          fontWeight: _droppedFilePath != null ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              TextField(
                controller: _inputController,
                maxLines: _mode == 1 ? 5 : 1,
                enabled: !_isLoading,
                decoration: InputDecoration(
                  labelText: _mode == 0 ? tr('Pointer or main JSON file address') : 'repository_index.json content',
                  hintText: _mode == 0 ? 'autonomi://<pointer / hash>' : '{"repository_name": "...", "mods": [...]}',
                  border: const OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 8),
            // Теги, которые репозиторий советует скрыть (hide_tags): добавлять
            // в скрытые или нет. Та же настройка, что в Settings → Addons.
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _autoHideTags,
              onChanged: _isLoading
                  ? null
                  : (v) {
                      setState(() => _autoHideTags = v ?? false);
                      widget.onAutoHideTagsChanged(_autoHideTags);
                    },
              title: Text(tr('Automatically add the tags recommended for hiding to the hidden tags')),
            ),
            if (_isLoading) ...[
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  SizedBox(width: 12),
                  Text(tr('Loading repository from Autonomi...'), style: TextStyle(color: Colors.orangeAccent)),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_isLoading)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Cancel')),
          ),
        ElevatedButton(
          onPressed: _isLoading
              ? null
              : () async {
                  try {
                    setState(() => _isLoading = true);
                    String jsonContent = '';
                    String? pointer;

                    if (_mode == 2) {
                      if (_droppedFilePath == null) {
                        throw Exception(tr('No .json file dropped'));
                      }
                      final file = File(_droppedFilePath!);
                      if (await file.exists()) {
                        jsonContent = await file.readAsString();
                      } else {
                        throw Exception(tr('Dropped file not found'));
                      }
                    } else if (_mode == 1) {
                      jsonContent = _inputController.text.trim();
                    } else if (_mode == 0) {
                      final inputVal = _inputController.text.trim();
                      final cleanHash = inputVal.replaceAll('autonomi://', '').trim();

                      if (!await AntdDaemon.ensureRunning()) {
                        throw Exception(tr('Autonomi daemon is not running'));
                      }
                      // Pointer или адрес самого файла.
                      final (text, viaPointer) = await AutonomiService.downloadRepository(cleanHash);
                      pointer = viaPointer;
                      if (text == null) {
                        throw Exception(tr('Failed to download index by Autonomi hash'));
                      }
                      jsonContent = text;
                    }

                    final decoded = jsonDecode(jsonContent);
                    final repoName = decoded['repository_name'] ?? tr('Unnamed Repository');

                    if (mounted) {
                      Navigator.of(context).pop({
                        'title': repoName,
                        'value': jsonContent,
                        if (pointer != null) 'pointer': pointer,
                      });
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() => _isLoading = false);
                      showSnack(context, 
                        SnackBar(content: Text(tr('Error: {error}', {'error': e})), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
          child: Text(_isLoading ? tr('Loading...') : tr('Connect')),
        ),
      ],
    );
  }
}