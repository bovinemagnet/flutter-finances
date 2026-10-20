import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/section_label.dart';
import '../../app/theme.dart';
import '../../format/formatters.dart';
import 'spending_pace.dart';

String _day(LocalDate date) => DateFormat(
  'EEE d',
  'en_AU',
).format(DateTime(date.year, date.month, date.day));

/// One headline figure with a spaced label and an optional caption.
class FigureTile extends StatelessWidget {
  const FigureTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.captionColour,
  });

  final String label;
  final String value;
  final String? caption;
  final Color? captionColour;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    return MergeSemantics(
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionLabel(label),
              const SizedBox(height: 8),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: palette.figure(size: 24)),
              ),
              if (caption != null) ...[
                const SizedBox(height: 6),
                Text(
                  caption!,
                  style: palette.figure(
                    size: 11,
                    weight: FontWeight.w500,
                    color: captionColour ?? palette.muted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Lays tiles out in equal columns that wrap on narrow widths.
class FigureRow extends StatelessWidget {
  const FigureRow({super.key, required this.children, this.minTileWidth = 160});

  final List<Widget> children;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0;
      final perRow = (constraints.maxWidth / minTileWidth).floor().clamp(
        1,
        children.length,
      );
      final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// Spending so far against the period budget, as a bar with both figures.
class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.pace});

  final SpendingPace pace;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final budget = pace.budget.minor;
    final value = budget <= 0 ? 1.0 : (pace.spent.minor / budget).clamp(0, 1);
    final style = palette.figure(
      size: 12,
      weight: FontWeight.w500,
      color: palette.muted,
    );
    return Semantics(
      container: true,
      label:
          '${formatMoney(pace.spent)} spent of a ${formatMoney(pace.budget)} budget',
      child: ExcludeSemantics(
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: value.toDouble(),
                minHeight: 8,
                color: pace.spent > pace.budget
                    ? palette.negative
                    : palette.accent,
                backgroundColor: palette.cardMuted,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text('${formatMoney(pace.spent)} spent', style: style),
                ),
                Text('${formatMoney(pace.budget)} budget', style: style),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Cumulative spending through the budget period against an even pace.
class SpendingPaceChart extends StatelessWidget {
  const SpendingPaceChart({super.key, required this.pace});

  final SpendingPace pace;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final period = pace.period;
    final ahead = pace.spent > pace.paceToday;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Spending this period',
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontSize: 17),
                    ),
                    Text(
                      '${_day(period.start)} to ${_day(period.end)}, against '
                      'your budget pace',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    _Legend(colour: palette.accent, label: 'Spent'),
                    _Legend(
                      colour: palette.muted,
                      label: 'Budget pace',
                      dashed: true,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Semantics(
              container: true,
              image: true,
              label:
                  'Spending chart: ${formatMoney(pace.spent)} spent so far, '
                  '${ahead ? 'ahead of' : 'within'} the budget pace of '
                  '${formatMoney(pace.paceToday)} for today, from a '
                  '${formatMoney(pace.budget)} budget',
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: CustomPaint(
                  painter: _PacePainter(pace: pace, palette: palette),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final text in [
                    _day(period.start),
                    'Today',
                    _day(period.end),
                  ])
                    Text(
                      text.toUpperCase(),
                      style: palette.label(
                        color: text == 'Today' ? palette.accentText : null,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.colour,
    required this.label,
    this.dashed = false,
  });

  final Color colour;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dashed ? 12 : 8,
          height: dashed ? 2 : 8,
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: palette.figure(
            size: 11,
            weight: FontWeight.w500,
            color: palette.muted,
          ),
        ),
      ],
    );
  }
}

class _PacePainter extends CustomPainter {
  _PacePainter({required this.pace, required this.palette});

  final SpendingPace pace;
  final FinancePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final days = pace.period.lengthDays;
    final top =
        [
          pace.budget.minor,
          pace.spent.minor,
          1,
        ].reduce((a, b) => a > b ? a : b) *
        1.1;
    Offset point(int dayIndex, int minor) => Offset(
      days <= 1 ? size.width : size.width * (dayIndex + 1) / days,
      size.height - size.height * minor / top,
    );
    final grid = Paint()
      ..color = palette.line
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final paceLine = Paint()
      ..color = palette.muted
      ..strokeWidth = 2;
    final end = point(days - 1, pace.budget.minor);
    final origin = Offset(0, size.height);
    const dash = 6.0;
    final length = (end - origin).distance;
    final step = (end - origin) / length;
    for (var d = 0.0; d < length; d += dash * 2) {
      final to = d + dash > length ? length : d + dash;
      canvas.drawLine(origin + step * d, origin + step * to, paceLine);
    }
    final points = [
      origin,
      for (var i = 0; i < pace.spentByDay.length; i++)
        point(i, pace.spentByDay[i].minor),
    ];
    final line = Path()..addPolygon(points, false);
    final area = Path()
      ..addPolygon([...points, Offset(points.last.dx, size.height)], true);
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.accent.withValues(alpha: 0.35),
            palette.accent.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = palette.accent
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(points.last, 6, Paint()..color = palette.card);
    canvas.drawCircle(
      points.last,
      6,
      Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_PacePainter old) =>
      old.pace != pace || old.palette != palette;
}

/// A titled card of rows with an optional link in its header.
class OverviewSection extends StatelessWidget {
  const OverviewSection({
    super.key,
    required this.title,
    required this.children,
    this.action,
    this.onAction,
  });

  final String title;
  final List<Widget> children;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
          child: Row(
            children: [
              Expanded(child: SectionLabel(title)),
              if (action != null)
                TextButton(onPressed: onAction, child: Text(action!)),
            ],
          ),
        ),
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const Divider(),
          child,
        ],
      ],
    ),
  );
}

/// A label, an optional detail line and a figure, in one row.
class FigureRowTile extends StatelessWidget {
  const FigureRowTile({
    super.key,
    required this.title,
    required this.amount,
    this.subtitle,
    this.leading,
    this.amountColour,
    this.onTap,
  });

  final String title;
  final String amount;
  final String? subtitle;
  final Widget? leading;
  final Color? amountColour;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    return ListTile(
      onTap: onTap,
      leading: leading,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Text(
        amount,
        style: palette.figure(size: 14, color: amountColour ?? palette.text),
      ),
    );
  }
}

/// A due date as a weekday over the day of the month.
class DueDate extends StatelessWidget {
  const DueDate(this.date, {super.key});
  final LocalDate date;

  @override
  Widget build(BuildContext context) {
    final palette = FinancePalette.of(context);
    final day = DateTime(date.year, date.month, date.day);
    return SizedBox(
      width: 40,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            DateFormat('EEE', 'en_AU').format(day).toUpperCase(),
            style: palette.figure(
              size: 10,
              weight: FontWeight.w500,
              color: palette.muted,
            ),
          ),
          Text('${date.day}', style: palette.figure(size: 17)),
        ],
      ),
    );
  }
}
