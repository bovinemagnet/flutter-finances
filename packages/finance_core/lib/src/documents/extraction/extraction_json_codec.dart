import '../../money/money.dart';
import '../../time/local_date.dart';
import 'extraction.dart';
import 'ocr_result.dart';

/// JSON format for extractions. Uncertainty reasons are written as their
/// stable codes (for example `AMBIGUOUS_DATE`).

UncertaintyReason _reason(String code) =>
    UncertaintyReason.values.firstWhere((r) => r.code == code);

Map<String, Object?> ocrResultToJson(OcrResult ocr) => {
  'engine': ocr.engine,
  'engineVersion': ocr.engineVersion,
  'lines': [
    for (final line in ocr.lines)
      {
        'text': line.text,
        if (line.box != null)
          'box': {
            'left': line.box!.left,
            'top': line.box!.top,
            'width': line.box!.width,
            'height': line.box!.height,
          },
        if (line.engineConfidence != null)
          'engineConfidence': line.engineConfidence,
      },
  ],
};

OcrResult ocrResultFromJson(Map<String, Object?> json) => OcrResult(
  engine: json['engine'] as String,
  engineVersion: json['engineVersion'] as String,
  lines: [
    for (final raw in (json['lines'] as List).cast<Map<String, Object?>>())
      OcrLine(
        raw['text'] as String,
        box: raw['box'] == null
            ? null
            : () {
                final b = (raw['box'] as Map).cast<String, Object?>();
                double n(String key) => (b[key] as num).toDouble();
                return BoundingBox(
                  n('left'),
                  n('top'),
                  n('width'),
                  n('height'),
                );
              }(),
        engineConfidence: (raw['engineConfidence'] as num?)?.toDouble(),
      ),
  ],
);

Map<String, Object?> _candidate<T>(
  FieldCandidate<T> candidate,
  Map<String, Object?> Function(T value) value,
) => {
  ...value(candidate.value),
  'sourceLines': candidate.sourceLines,
  'sourceText': candidate.sourceText,
  'confidence': candidate.confidence.name,
  'reasons': [for (final r in candidate.reasons) r.code],
};

FieldCandidate<T> _candidateFrom<T>(
  Map<String, Object?> json,
  T Function(Map<String, Object?> json) value,
) => FieldCandidate(
  value: value(json),
  sourceLines: (json['sourceLines'] as List).cast<int>(),
  sourceText: json['sourceText'] as String,
  confidence: ConfidenceCategory.values.byName(json['confidence'] as String),
  reasons: {
    for (final code in (json['reasons'] as List).cast<String>()) _reason(code),
  },
);

Map<String, Object?> _text(String value) => {'value': value};
Map<String, Object?> _localDate(LocalDate value) => {'value': '$value'};
Map<String, Object?> _money(Money value) => {
  'valueMinor': value.minor,
  'currency': value.currency.code,
  'currencyExponent': value.currency.exponent,
};

String _readText(Map<String, Object?> json) => json['value'] as String;
LocalDate _readDate(Map<String, Object?> json) =>
    LocalDate.parse(json['value'] as String);
Money _readMoney(Map<String, Object?> json) => Money(
  json['valueMinor'] as int,
  Currency(json['currency'] as String, json['currencyExponent'] as int),
);

List<Map<String, Object?>> _list(Object? json) =>
    (json as List? ?? const []).cast<Map<String, Object?>>();

Map<String, Object?> extractionToJson(Extraction e) => {
  'id': e.id,
  'receiptId': e.receiptId,
  'createdAt': e.createdAt.toUtc().toIso8601String(),
  'extractionVersion': e.extractionVersion,
  'ocr': ocrResultToJson(e.ocr),
  'merchant': [for (final c in e.merchant) _candidate(c, _text)],
  'date': [for (final c in e.date) _candidate(c, _localDate)],
  'total': [for (final c in e.total) _candidate(c, _money)],
  'tax': [for (final c in e.tax) _candidate(c, _money)],
  'currency': [for (final c in e.currency) _candidate(c, _text)],
  'subtotal': e.subtotal == null ? null : _candidate(e.subtotal!, _money),
  'cashTendered': e.cashTendered == null
      ? null
      : _candidate(e.cashTendered!, _money),
  'change': e.change == null ? null : _candidate(e.change!, _money),
  'isRefund': e.isRefund,
  'arithmetic': e.arithmetic.name,
  'reviewReasons': [for (final r in e.reviewReasons) r.code],
};

Extraction extractionFromJson(Map<String, Object?> json) {
  FieldCandidate<Money>? single(Object? value) => value == null
      ? null
      : _candidateFrom((value as Map).cast<String, Object?>(), _readMoney);
  return Extraction(
    id: json['id'] as String,
    receiptId: json['receiptId'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    extractionVersion: json['extractionVersion'] as String,
    ocr: ocrResultFromJson((json['ocr'] as Map).cast<String, Object?>()),
    merchant: [
      for (final c in _list(json['merchant'])) _candidateFrom(c, _readText),
    ],
    date: [for (final c in _list(json['date'])) _candidateFrom(c, _readDate)],
    total: [
      for (final c in _list(json['total'])) _candidateFrom(c, _readMoney),
    ],
    tax: [for (final c in _list(json['tax'])) _candidateFrom(c, _readMoney)],
    currency: [
      for (final c in _list(json['currency'])) _candidateFrom(c, _readText),
    ],
    subtotal: single(json['subtotal']),
    cashTendered: single(json['cashTendered']),
    change: single(json['change']),
    isRefund: json['isRefund'] as bool,
    arithmetic: ArithmeticCheck.values.byName(json['arithmetic'] as String),
    reviewReasons: {
      for (final code in (json['reviewReasons'] as List).cast<String>())
        _reason(code),
    },
  );
}
