import 'package:flutter/material.dart';

/// Body text.
const bodyFont = 'Inter';

/// Headings and screen titles.
const headingFont = 'Space Grotesk';

/// Amounts, dates and small labels.
const figureFont = 'JetBrains Mono';

/// The app's colour tokens: a dark-first ground with one mint accent and
/// amber reserved for things that need the user (pending, stale, unsure).
///
/// [accent] is a fill (buttons, bars, chart lines) read with [onAccent];
/// text in the accent colour uses [accentText], which meets 4.5:1 on cards
/// in both modes.
@immutable
class FinancePalette extends ThemeExtension<FinancePalette> {
  const FinancePalette({
    required this.brightness,
    required this.background,
    required this.sidebar,
    required this.card,
    required this.cardMuted,
    required this.field,
    required this.line,
    required this.fieldLine,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.accentText,
    required this.accentSoft,
    required this.negative,
    required this.warning,
    required this.warningSoft,
    required this.warningLine,
    required this.onWarningSoft,
  });

  static const dark = FinancePalette(
    brightness: Brightness.dark,
    background: Color(0xFF0B0D0E),
    sidebar: Color(0xFF0F1213),
    card: Color(0xFF15181A),
    cardMuted: Color(0xFF23282B),
    field: Color(0xFF101315),
    line: Color(0xFF262C2F),
    fieldLine: Color(0xFF3A4246),
    text: Color(0xFFEEF2F0),
    muted: Color(0xFF9BA6A2),
    accent: Color(0xFF19E3A0),
    onAccent: Color(0xFF03251A),
    accentText: Color(0xFF3CEDB0),
    accentSoft: Color(0xFF0F2C22),
    negative: Color(0xFFFF8A80),
    warning: Color(0xFFF5B94A),
    warningSoft: Color(0xFF241C0C),
    warningLine: Color(0xFF4A3714),
    onWarningSoft: Color(0xFFF7CB78),
  );

  static const light = FinancePalette(
    brightness: Brightness.light,
    background: Color(0xFFF3F6F5),
    sidebar: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    cardMuted: Color(0xFFE6ECE9),
    field: Color(0xFFFFFFFF),
    line: Color(0xFFDDE5E1),
    fieldLine: Color(0xFFA9B5B2),
    text: Color(0xFF101715),
    muted: Color(0xFF56625E),
    accent: Color(0xFF19D696),
    onAccent: Color(0xFF03251A),
    accentText: Color(0xFF007A52),
    accentSoft: Color(0xFFDDF7EC),
    negative: Color(0xFFB3261E),
    warning: Color(0xFFC98A12),
    warningSoft: Color(0xFFFFF4DE),
    warningLine: Color(0xFFF0D29A),
    onWarningSoft: Color(0xFF5C3A00),
  );

  final Brightness brightness;
  final Color background;
  final Color sidebar;
  final Color card;
  final Color cardMuted;
  final Color field;
  final Color line;
  final Color fieldLine;
  final Color text;
  final Color muted;
  final Color accent;
  final Color onAccent;
  final Color accentText;
  final Color accentSoft;
  final Color negative;
  final Color warning;
  final Color warningSoft;
  final Color warningLine;
  final Color onWarningSoft;

  /// The palette of the current theme, or the default one for its
  /// brightness when the theme was not built by [buildTheme].
  static FinancePalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<FinancePalette>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  /// Secondary text and dividers at full strength for high contrast.
  FinancePalette get highContrast =>
      copyWith(muted: text, line: fieldLine, fieldLine: text);

  /// Monospaced, tabular figures for amounts and dates.
  TextStyle figure({
    double? size,
    FontWeight weight = FontWeight.w700,
    Color? color,
  }) => TextStyle(
    fontFamily: figureFont,
    fontSize: size,
    fontWeight: weight,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Small spaced capitals used above sections and figures; pass the text
  /// already in capitals (see `SectionLabel`).
  TextStyle label({Color? color}) => TextStyle(
    fontFamily: figureFont,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.5,
    color: color ?? muted,
  );

  @override
  FinancePalette copyWith({
    Color? background,
    Color? sidebar,
    Color? card,
    Color? cardMuted,
    Color? field,
    Color? line,
    Color? fieldLine,
    Color? text,
    Color? muted,
    Color? accent,
    Color? onAccent,
    Color? accentText,
    Color? accentSoft,
    Color? negative,
    Color? warning,
    Color? warningSoft,
    Color? warningLine,
    Color? onWarningSoft,
  }) => FinancePalette(
    brightness: brightness,
    background: background ?? this.background,
    sidebar: sidebar ?? this.sidebar,
    card: card ?? this.card,
    cardMuted: cardMuted ?? this.cardMuted,
    field: field ?? this.field,
    line: line ?? this.line,
    fieldLine: fieldLine ?? this.fieldLine,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    accentText: accentText ?? this.accentText,
    accentSoft: accentSoft ?? this.accentSoft,
    negative: negative ?? this.negative,
    warning: warning ?? this.warning,
    warningSoft: warningSoft ?? this.warningSoft,
    warningLine: warningLine ?? this.warningLine,
    onWarningSoft: onWarningSoft ?? this.onWarningSoft,
  );

  @override
  FinancePalette lerp(FinancePalette? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

ColorScheme _scheme(FinancePalette p) {
  final dark = p.brightness == Brightness.dark;
  return ColorScheme(
    brightness: p.brightness,
    // Primary is used for text and icons, so it is the readable accent;
    // the mint fill is the primary container (buttons, the add action).
    primary: p.accentText,
    onPrimary: dark ? p.onAccent : Colors.white,
    primaryContainer: p.accent,
    onPrimaryContainer: p.onAccent,
    secondary: p.accentText,
    onSecondary: dark ? p.onAccent : Colors.white,
    secondaryContainer: p.accentSoft,
    onSecondaryContainer: p.accentText,
    tertiary: dark ? p.warning : const Color(0xFF7A4E00),
    onTertiary: dark ? const Color(0xFF2B1A00) : Colors.white,
    tertiaryContainer: p.warningSoft,
    onTertiaryContainer: p.onWarningSoft,
    error: p.negative,
    onError: dark ? const Color(0xFF3B0906) : Colors.white,
    errorContainer: dark ? const Color(0xFF3B1412) : const Color(0xFFFFDAD6),
    onErrorContainer: dark ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
    surface: p.background,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    surfaceDim: p.background,
    surfaceBright: p.card,
    surfaceContainerLowest: p.background,
    surfaceContainerLow: p.card,
    surfaceContainer: p.card,
    surfaceContainerHigh: p.cardMuted,
    surfaceContainerHighest: p.cardMuted,
    outline: p.fieldLine,
    outlineVariant: p.line,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: p.text,
    onInverseSurface: p.background,
    inversePrimary: dark ? FinancePalette.light.accentText : p.accent,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildTheme(Brightness brightness, {bool highContrast = false}) {
  var palette = brightness == Brightness.dark
      ? FinancePalette.dark
      : FinancePalette.light;
  if (highContrast) palette = palette.highContrast;
  final scheme = _scheme(palette);
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: bodyFont,
  );
  TextStyle? heading(TextStyle? style, FontWeight weight) => style?.copyWith(
    fontFamily: headingFont,
    fontWeight: weight,
    letterSpacing: -0.2,
  );
  final text = base.textTheme;
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
  );
  return base.copyWith(
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: palette.background,
    textTheme: text.copyWith(
      displayLarge: heading(text.displayLarge, FontWeight.w700),
      displayMedium: heading(text.displayMedium, FontWeight.w700),
      displaySmall: heading(text.displaySmall, FontWeight.w700),
      headlineLarge: heading(text.headlineLarge, FontWeight.w700),
      headlineMedium: heading(text.headlineMedium, FontWeight.w700),
      headlineSmall: heading(text.headlineSmall, FontWeight.w700),
      titleLarge: heading(text.titleLarge, FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    ),
    extensions: [palette],
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.text,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: headingFont,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: palette.text,
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: palette.line),
      ),
    ),
    dividerTheme: DividerThemeData(color: palette.line, space: 1),
    listTileTheme: ListTileThemeData(iconColor: palette.muted),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.card,
      indicatorColor: palette.accentSoft,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? palette.accentText
              : palette.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? palette.accentText
              : palette.muted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: palette.sidebar,
      indicatorColor: palette.accentSoft,
      selectedIconTheme: IconThemeData(color: palette.accentText),
      unselectedIconTheme: IconThemeData(color: palette.muted),
      selectedLabelTextStyle: TextStyle(
        fontWeight: FontWeight.w600,
        color: palette.accentText,
      ),
      unselectedLabelTextStyle: TextStyle(color: palette.muted),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.accent,
      foregroundColor: palette.onAccent,
      elevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      extendedTextStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        shape: rounded,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.text,
        side: BorderSide(color: palette.fieldLine),
        shape: rounded,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accentText,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: palette.line),
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.field,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.fieldLine),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.accent,
      linearTrackColor: palette.cardMuted,
    ),
  );
}

/// Colours that carry meaning are always paired with text or an icon, so
/// state is never conveyed by colour alone (UX 01).
extension FinanceColours on ColorScheme {
  Color get positiveAmount => brightness == Brightness.light
      ? FinancePalette.light.accentText
      : FinancePalette.dark.accentText;
  Color get negativeAmount => error;
}
