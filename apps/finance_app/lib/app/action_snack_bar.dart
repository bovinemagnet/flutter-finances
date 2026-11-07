import 'package:flutter/material.dart';

VoidCallback? _closeShowing;

/// Shows [content] with a button. Flutter would keep a snackbar with an action
/// on screen until it is dismissed, covering what is under it; this one goes
/// after the usual time, except for someone using a screen reader, who needs
/// as long as it takes to reach the button. Either way it goes when a new page
/// opens (see [ActionSnackBarObserver]), where it could cover that page's
/// buttons.
void showActionSnackBar(
  ScaffoldMessengerState messenger, {
  required Widget content,
  required String label,
  required VoidCallback onPressed,
}) {
  late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> bar;
  void close() {
    if (messenger.mounted) bar.close();
  }

  bar = messenger.showSnackBar(
    SnackBar(
      content: content,
      persist: MediaQuery.accessibleNavigationOf(messenger.context),
      action: SnackBarAction(label: label, onPressed: onPressed),
      onVisible: () => _closeShowing = close,
    ),
  );
  bar.closed.whenComplete(() {
    if (_closeShowing == close) _closeShowing = null;
  });
}

/// Clears the message from [showActionSnackBar] when a new page opens. A dialog
/// or menu leaves it, because it is still there once they close.
class ActionSnackBarObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) _closeShowing?.call();
  }
}
