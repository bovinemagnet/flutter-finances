import 'package:meta/meta.dart';

/// Row-level import problems (IMP 01). Codes are shared with the server.
enum ImportErrorCode {
  unterminatedQuote('UNTERMINATED_QUOTE'),
  columnNotFound('COLUMN_NOT_FOUND'),
  missingField('MISSING_FIELD'),
  badDate('BAD_DATE'),
  badAmount('BAD_AMOUNT'),
  missingAmount('MISSING_AMOUNT'),
  bothDebitAndCredit('BOTH_DEBIT_AND_CREDIT'),
  zeroAmount('ZERO_AMOUNT'),

  /// The file is not in the expected format (OFX or QIF); reported on
  /// row 0, the file as a whole.
  unrecognisedFormat('UNRECOGNISED_FORMAT');

  const ImportErrorCode(this.code);
  final String code;
}

/// An error tied to a 1-based record number in the file (the header, when
/// present, is record 1).
@immutable
class ImportRowError {
  const ImportRowError(this.row, this.code, this.message);

  final int row;
  final ImportErrorCode code;
  final String message;

  @override
  String toString() => 'Row $row: ${code.code} $message';
}
