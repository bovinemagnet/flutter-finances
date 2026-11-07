import 'package:flutter/material.dart';

/// Shows [content] with a button. Flutter would keep a snackbar with an action
/// on screen until it is dismissed, covering what is under it; this one goes
/// after the usual time, except for someone using a screen reader, who needs
/// as long as it takes to reach the button.
void showActionSnackBar(
  ScaffoldMessengerState messenger, {
  required Widget content,
  required String label,
  required VoidCallback onPressed,
}) {
  messenger.showSnackBar(
    SnackBar(
      content: content,
      persist: MediaQuery.accessibleNavigationOf(messenger.context),
      action: SnackBarAction(label: label, onPressed: onPressed),
    ),
  );
}
