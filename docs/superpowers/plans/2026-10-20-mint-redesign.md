# Mint Redesign Implementation Plan

**Goal:** Bring the Flutter app in line with the approved "Finance App Screens" canvas: mint green on a dark-first palette, Space Grotesk headings, JetBrains Mono figures and labels, a grouped desktop sidebar, and a redesigned Overview for phone and desktop.

**Architecture:** Colours and type live in `lib/app/theme.dart` as two palettes (dark, light) turned into Material 3 `ThemeData`, with a `FinancePalette` theme extension for the tokens Material has no slot for (warning colours, figure text). Screens pick colours from the theme only. The desktop sidebar replaces the extended `NavigationRail`; compact and medium widths keep the bottom bar and rail. The Overview gets a hero "available until payday" card, figure tiles and, on expanded widths, a two-column dashboard with a spending-pace chart.

**Tech stack:** Flutter (Material 3), bundled OFL fonts, `CustomPainter` for the chart.

## Global constraints

- Fonts are bundled, never fetched at run time; each font's OFL licence is bundled and registered with `LicenseRegistry`.
- Text contrast is at least 4.5:1 in both modes; meaning is never carried by colour alone (signs on amounts, text on tags).
- The theme follows the system light/dark setting; high-contrast variants stay.
- Layout is chosen by width class (compact < 600, medium 600–1023, expanded ≥ 1024), never by operating system.
- British spelling in UI text; no new financial rules (presentation only).

## Tasks

- [x] **T1 Fonts:** add `assets/fonts` (Inter and Space Grotesk variable fonts, JetBrains Mono Regular/Medium/Bold) with their OFL licences, declare them in `pubspec.yaml`, register the licences at start-up.
- [x] **T2 Theme (TDD):** test that every text token pair meets 4.5:1 in both palettes; then build `FinancePalette` (dark and light tokens), the colour schemes, text theme and component themes (cards, buttons, chips, inputs, navigation). `FinanceColours.positiveAmount` follows the palette.
- [x] **T3 Spending pace (TDD):** a pure function returning cumulative posted spending per day of the budget period and the budget total, tested against `LedgerProjection.expenses`.
- [x] **T4 Shell:** expanded widths get a sidebar grouped Money / Plan / Review with Settings at the foot and shortcut hints; tests updated for the sidebar.
- [x] **T5 Overview:** hero available card with budget bar, figure tiles, restyled money and needs-attention sections; expanded layout with figure row, spending chart, recent transactions and side column. Widget tests for both widths.
- [x] **T6 Figures across screens:** amounts and dates in the figure style in the transaction list and bank feed screen; status tags restyled.
- [x] **T7 Verify:** `flutter analyze`, all app tests, `dart test` in both packages, Linux release build, launch and screenshot in both modes.
- [x] **T8 Docs:** describe the look, fonts and licences in `src/docs`; `gradle25w antora` clean.
