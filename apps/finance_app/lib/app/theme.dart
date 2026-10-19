import 'package:flutter/material.dart';

const _seed = Color(0xFF00696B);

ThemeData buildTheme(Brightness brightness, {bool highContrast = false}) {
  var scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
    contrastLevel: highContrast ? 1.0 : 0.0,
  );
  if (highContrast) {
    scheme = scheme.copyWith(
      outline: brightness == Brightness.light ? Colors.black : Colors.white,
    );
  }
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );
}

/// Colours that carry meaning are always paired with text or an icon, so
/// state is never conveyed by colour alone (UX 01).
extension FinanceColours on ColorScheme {
  Color get positiveAmount => brightness == Brightness.light
      ? const Color(0xFF1B6B2F)
      : const Color(0xFF8BD89A);
  Color get negativeAmount => error;
}
