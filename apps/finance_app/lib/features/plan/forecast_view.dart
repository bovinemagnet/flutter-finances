import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';

import '../../format/formatters.dart';

const certaintyLabels = {
  ForecastCertainty.actual: 'Actual',
  ForecastCertainty.committed: 'Committed',
  ForecastCertainty.hypothetical: 'Hypothetical',
};

enum ForecastPresentation { chart, table }

/// Day-by-day cash projection with chart and table alternatives (PLAN 03).
/// Certainty is written next to each line, never shown by colour alone.
class ForecastView extends StatefulWidget {
  const ForecastView({super.key, required this.forecast, this.onOpenSource});

  final CashForecast forecast;
  final ValueChanged<ForecastLine>? onOpenSource;

  @override
  State<ForecastView> createState() => _ForecastViewState();
}

class _ForecastViewState extends State<ForecastView> {
  var _mode = ForecastPresentation.chart;

  @override
  Widget build(BuildContext context) {
    final forecast = widget.forecast;
    final theme = Theme.of(context);
    final days = forecast.days.where((d) => d.lines.isNotEmpty).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Cash forecast ${formatDate(forecast.start)} to ${formatDate(forecast.end)}',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          color: forecast.lowestBalance.isNegative
              ? theme.colorScheme.errorContainer
              : null,
          child: ListTile(
            leading: Icon(
              forecast.lowestBalance.isNegative
                  ? Icons.warning_amber_outlined
                  : Icons.trending_flat,
            ),
            title: Text(
              'Lowest balance ${formatMoney(forecast.lowestBalance)}',
            ),
            subtitle: Text(
              'On ${formatDate(forecast.lowestDate)}'
              '${forecast.includesHypothetical ? ' · includes hypothetical changes' : ''}',
            ),
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<ForecastPresentation>(
          segments: const [
            ButtonSegment(
              value: ForecastPresentation.chart,
              icon: Icon(Icons.show_chart),
              label: Text('Chart'),
            ),
            ButtonSegment(
              value: ForecastPresentation.table,
              icon: Icon(Icons.table_rows_outlined),
              label: Text('Table'),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.single),
        ),
        const SizedBox(height: 16),
        if (_mode == ForecastPresentation.chart)
          Semantics(
            label:
                'Forecast chart. Opening ${formatMoney(forecast.openingBalance)}, '
                'lowest ${formatMoney(forecast.lowestBalance)} on ${formatDate(forecast.lowestDate)}, '
                'closing ${formatMoney(forecast.days.last.closing)}. Switch to the table for each day.',
            excludeSemantics: true,
            child: SizedBox(
              height: 200,
              child: CustomPaint(
                painter: _BalancePainter(
                  forecast.days.map((d) => d.closing.minor).toList(),
                  theme.colorScheme.primary,
                  theme.colorScheme.error,
                ),
                size: Size.infinite,
              ),
            ),
          )
        else
          for (final day in days) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '${formatDate(day.date)} · closing ${formatMoney(day.closing)}',
                style: theme.textTheme.titleSmall,
              ),
            ),
            for (final line in day.lines)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                onTap: widget.onOpenSource == null
                    ? null
                    : () => widget.onOpenSource!(line),
                title: Text(line.description ?? line.source.name),
                subtitle: Text(certaintyLabels[line.certainty]!),
                trailing: Text(formatMoney(line.amount, signed: true)),
              ),
          ],
      ],
    );
  }
}

class _BalancePainter extends CustomPainter {
  _BalancePainter(this.values, this.colour, this.negativeColour);
  final List<int> values;
  final Color colour;
  final Color negativeColour;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minValue = values.reduce((a, b) => a < b ? a : b).clamp(-1 << 62, 0);
    final maxValue = values.reduce((a, b) => a > b ? a : b);
    final span = (maxValue - minValue) == 0 ? 1 : maxValue - minValue;
    double y(int v) => size.height - (v - minValue) / span * size.height;
    final zero = Paint()
      ..color = negativeColour
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y(0)), Offset(size.width, y(0)), zero);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      i == 0 ? path.moveTo(x, y(values[i])) : path.lineTo(x, y(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_BalancePainter old) => old.values != values;
}
