import 'package:flutter/material.dart';

/// The height of the add and scan buttons that the compact layout floats over
/// every page, with their margin and the gap above them.
const compactActionsClearance = 144.0;

/// The height of a page's own floating button, with the gap above it.
const pageActionClearance = 72.0;

/// Reports the compact layout's floating buttons as padding below [child], so
/// that scrolling views with no padding of their own end clear of them.
class CompactActionsInset extends StatelessWidget {
  const CompactActionsInset({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: data.copyWith(
        padding: data.padding.copyWith(
          bottom: data.padding.bottom + compactActionsClearance,
        ),
      ),
      child: child,
    );
  }
}

/// Lifts a page's floating button above the compact layout's buttons.
///
/// [pageContext] must be from outside the page's own [Scaffold], which removes
/// padding from its floating button.
Widget aboveCompactActions(BuildContext pageContext, Widget button) => Padding(
  padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(pageContext).bottom),
  child: button,
);

/// Padding for the end of a scrolling view that sets its own padding.
double listEndPadding(
  BuildContext context, {
  double base = 16,
  bool hasPageAction = false,
}) =>
    base +
    MediaQuery.paddingOf(context).bottom +
    (hasPageAction ? pageActionClearance : 0);
