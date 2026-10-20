import 'package:finance_app/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final (name, palette) in [
    ('dark', FinancePalette.dark),
    ('light', FinancePalette.light),
  ]) {
    group('$name palette', () {
      final pairs = {
        'text on background': (palette.text, palette.background),
        'text on card': (palette.text, palette.card),
        'muted on background': (palette.muted, palette.background),
        'muted on card': (palette.muted, palette.card),
        'accent text on card': (palette.accentText, palette.card),
        'accent text on accent soft': (palette.accentText, palette.accentSoft),
        'ink on accent': (palette.onAccent, palette.accent),
        'negative on card': (palette.negative, palette.card),
        'warning text on warning soft': (
          palette.onWarningSoft,
          palette.warningSoft,
        ),
      };
      for (final MapEntry(key: label, value: (fg, bg)) in pairs.entries) {
        test('$label meets 4.5:1', () {
          expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5));
        });
      }
    });
  }

  test('themes carry the palette, the mint fills and the bundled fonts', () {
    for (final brightness in Brightness.values) {
      final theme = buildTheme(brightness);
      final palette = theme.extension<FinancePalette>()!;
      expect(palette.brightness, brightness);
      expect(theme.colorScheme.primaryContainer, palette.accent);
      expect(theme.scaffoldBackgroundColor, palette.background);
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Inter');
      expect(theme.textTheme.headlineSmall!.fontFamily, 'Space Grotesk');
      expect(palette.figure().fontFamily, 'JetBrains Mono');
      for (final style in [
        theme.textButtonTheme.style,
        theme.filledButtonTheme.style,
      ]) {
        expect(
          style!.textStyle!.resolve({})!.fontFamily,
          'Inter',
          reason: 'button text keeps the body font',
        );
      }
      expect(
        theme.floatingActionButtonTheme.extendedTextStyle!.fontFamily,
        'Inter',
      );
      expect(
        theme.colorScheme.positiveAmount,
        palette.accentText,
        reason: 'money in uses the readable accent',
      );
    }
  });

  test('high contrast raises secondary text to the main text colour', () {
    final theme = buildTheme(Brightness.dark, highContrast: true);
    final palette = theme.extension<FinancePalette>()!;
    expect(palette.muted, palette.text);
  });
}
