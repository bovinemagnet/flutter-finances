import 'package:flutter/material.dart';

import 'theme.dart';

/// Small spaced capitals above a section or figure. Screen readers hear the
/// text as written, not spelt out letter by letter.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    label: text,
    child: ExcludeSemantics(
      child: Text(
        text.toUpperCase(),
        style: FinancePalette.of(context).label(color: color),
      ),
    ),
  );
}
