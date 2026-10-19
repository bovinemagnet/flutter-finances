import 'package:finance_core/finance_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format/formatters.dart';
import 'amount_expression.dart';

/// Calculator-style amount entry (FIN 03). Accepts `12.50+3.25` or
/// `3 x 4.10`, shows the evaluated total, and offers an on-screen keypad.
class AmountField extends StatefulWidget {
  const AmountField({
    super.key,
    required this.currency,
    required this.initialText,
    required this.onChanged,
    this.errorText,
    this.label = 'Amount',
    this.autofocus = false,
  });

  final Currency currency;
  final String initialText;
  final ValueChanged<String> onChanged;
  final String? errorText;
  final String label;
  final bool autofocus;

  @override
  State<AmountField> createState() => _AmountFieldState();
}

class _AmountFieldState extends State<AmountField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _evaluated {
    final text = _controller.text;
    if (!RegExp(r'[+\-x×*]').hasMatch(text.replaceFirst(RegExp(r'^-'), ''))) {
      return null;
    }
    try {
      return '= ${formatMoney(evaluateAmountExpression(text, widget.currency))}';
    } on FormatException {
      return null;
    }
  }

  void _set(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    widget.onChanged(text);
    setState(() {});
  }

  Future<void> _openKeypad() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => AmountKeypad(initial: _controller.text),
    );
    if (result != null) _set(result);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      keyboardType: TextInputType.text,
      textInputAction: TextInputAction.next,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,+\-x×*$ ]')),
      ],
      style: Theme.of(context).textTheme.headlineSmall,
      decoration: InputDecoration(
        labelText: widget.label,
        prefixText: r'$ ',
        helperText: _evaluated,
        errorText: widget.errorText,
        suffixIcon: IconButton(
          tooltip: 'Open calculator keypad',
          icon: const Icon(Icons.calculate_outlined),
          onPressed: _openKeypad,
        ),
      ),
      onChanged: (text) {
        widget.onChanged(text);
        setState(() {});
      },
    );
  }
}

/// On-screen keypad returning the edited expression.
class AmountKeypad extends StatefulWidget {
  const AmountKeypad({super.key, required this.initial});
  final String initial;

  @override
  State<AmountKeypad> createState() => _AmountKeypadState();
}

class _AmountKeypadState extends State<AmountKeypad> {
  late String _text = widget.initial;

  static const _keys = [
    '7', '8', '9', '+', //
    '4', '5', '6', '-',
    '1', '2', '3', '×',
    '.', '0', '⌫', 'Done',
  ];

  void _press(String key) {
    setState(() {
      switch (key) {
        case '⌫':
          if (_text.isNotEmpty) _text = _text.substring(0, _text.length - 1);
        case 'Done':
          Navigator.of(context).pop(_text);
        default:
          _text += key;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              liveRegion: true,
              label: 'Amount',
              child: Text(
                _text.isEmpty ? '0' : _text,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 12),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.6,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final key in _keys)
                  key == 'Done'
                      ? FilledButton(
                          onPressed: () => _press(key),
                          child: const Text('Done'),
                        )
                      : OutlinedButton(
                          onPressed: () => _press(key),
                          child: Semantics(
                            label: key == '⌫' ? 'Delete' : null,
                            child: Text(
                              key,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                        ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
