import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../platform/image_tools.dart';

/// Manual readability fixes for a receipt photo (REC 02): rotate, crop and
/// enhance contrast. Every control is a button or slider, so it works with
/// a keyboard and screen reader as well as touch.
class ImageEditScreen extends StatefulWidget {
  const ImageEditScreen({super.key, required this.source});
  final Uint8List source;

  @override
  State<ImageEditScreen> createState() => _ImageEditScreenState();
}

class _ImageEditScreenState extends State<ImageEditScreen> {
  var _turns = 0;
  var _contrast = false;
  var _crop = const RangeValues(0, 1);
  var _cropVertical = const RangeValues(0, 1);
  Uint8List? _preview;

  ImageEdits get _edits => ImageEdits(
    quarterTurns: _turns,
    enhanceContrast: _contrast,
    crop:
        _crop == const RangeValues(0, 1) &&
            _cropVertical == const RangeValues(0, 1)
        ? null
        : CropRect(
            _crop.start,
            _cropVertical.start,
            _crop.end - _crop.start,
            _cropVertical.end - _cropVertical.start,
          ),
  );

  @override
  void initState() {
    super.initState();
    _render();
  }

  void _render() =>
      setState(() => _preview = applyEdits(widget.source, _edits));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Make it readable'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_edits),
            child: const Text('Save copy'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _preview == null
                ? const Center(child: CircularProgressIndicator())
                : InteractiveViewer(
                    child: Image.memory(
                      _preview!,
                      fit: BoxFit.contain,
                      semanticLabel: 'Edited receipt preview',
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.rotate_left),
                      label: const Text('Rotate left'),
                      onPressed: () {
                        _turns = (_turns + 3) % 4;
                        _render();
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.rotate_right),
                      label: const Text('Rotate right'),
                      onPressed: () {
                        _turns = (_turns + 1) % 4;
                        _render();
                      },
                    ),
                    FilterChip(
                      label: const Text('Enhance faded text'),
                      selected: _contrast,
                      onSelected: (v) {
                        _contrast = v;
                        _render();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(width: 96, child: Text('Crop sides')),
                    Expanded(
                      child: RangeSlider(
                        values: _crop,
                        divisions: 20,
                        labels: RangeLabels(
                          '${(_crop.start * 100).round()}%',
                          '${(_crop.end * 100).round()}%',
                        ),
                        onChanged: (v) => setState(() => _crop = v),
                        onChangeEnd: (_) => _render(),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(
                      width: 96,
                      child: Text('Crop top and bottom'),
                    ),
                    Expanded(
                      child: RangeSlider(
                        values: _cropVertical,
                        divisions: 20,
                        labels: RangeLabels(
                          '${(_cropVertical.start * 100).round()}%',
                          '${(_cropVertical.end * 100).round()}%',
                        ),
                        onChanged: (v) => setState(() => _cropVertical = v),
                        onChangeEnd: (_) => _render(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
