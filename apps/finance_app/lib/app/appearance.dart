import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Light, dark or follow the system. A device-local choice kept in a file
/// beside the workspace (not synced), read before the app starts so the
/// unlock and setup screens use it too.
class Appearance extends ValueNotifier<ThemeMode> {
  Appearance._(this._file, super.value);

  /// For tests and previews: the choice is not saved.
  Appearance.inMemory([ThemeMode mode = ThemeMode.system]) : this._(null, mode);

  final File? _file;

  static Future<Appearance> load(File file) async {
    var mode = ThemeMode.system;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map) {
        mode = ThemeMode.values.asNameMap()[json['themeMode']] ?? mode;
      }
    } on Object {
      // Missing or unreadable: follow the system.
    }
    return Appearance._(file, mode);
  }

  Future<void> setMode(ThemeMode mode) async {
    value = mode;
    await _file?.writeAsString(jsonEncode({'themeMode': mode.name}));
  }
}

/// The appearance choice for the settings page.
class AppearanceTile extends StatelessWidget {
  const AppearanceTile({super.key, required this.appearance});

  final Appearance appearance;

  static const _descriptions = {
    ThemeMode.system: 'Follows this device',
    ThemeMode.light: 'Always light',
    ThemeMode.dark: 'Always dark',
  };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: appearance,
    builder: (context, mode, _) => ListTile(
      leading: const Icon(Icons.contrast),
      title: const Text('Appearance'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) =>
                  appearance.setMode(selection.single),
            ),
            const SizedBox(height: 6),
            Text(_descriptions[mode]!),
          ],
        ),
      ),
    ),
  );
}
