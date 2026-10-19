import 'package:meta/meta.dart';

import 'import_errors.dart';

/// One CSV record with its 1-based record number in the file.
@immutable
class CsvRecord {
  CsvRecord(this.number, List<String> fields)
    : fields = List.unmodifiable(fields);

  final int number;
  final List<String> fields;
}

@immutable
class CsvReadResult {
  CsvReadResult(List<CsvRecord> records, List<ImportRowError> errors)
    : records = List.unmodifiable(records),
      errors = List.unmodifiable(errors);

  final List<CsvRecord> records;
  final List<ImportRowError> errors;
}

const _quote = 0x22;
const _cr = 0x0D;
const _lf = 0x0A;

/// Reads delimited text following RFC 4180.
///
/// - Records end at CRLF, LF or CR outside quotes.
/// - A field starting with `"` is quoted; `""` inside it is one quote and
///   delimiters and line breaks are literal.
/// - Quotes elsewhere (inside an unquoted field, or after a closing quote)
///   are kept literally rather than rejected.
/// - Blank records (an empty line) are skipped but still counted, so record
///   numbers match the line a user sees in a spreadsheet.
/// - An unterminated quote reports `UNTERMINATED_QUOTE` at the record where
///   it opened and discards that partial record.
CsvReadResult readCsv(String text, {String delimiter = ','}) {
  if (delimiter.length != 1) {
    throw ArgumentError.value(delimiter, 'delimiter', 'must be one character');
  }
  final delim = delimiter.codeUnitAt(0);
  final records = <CsvRecord>[];
  final errors = <ImportRowError>[];
  final length = text.length;
  var fields = <String>[];
  var number = 1;
  var i = 0;

  void endRecord() {
    if (!(fields.length == 1 && fields.first.isEmpty)) {
      records.add(CsvRecord(number, fields));
    }
    fields = <String>[];
    number++;
  }

  while (i < length) {
    var c = text.codeUnitAt(i);
    if (c == _quote) {
      // Quoted field.
      final buffer = StringBuffer();
      final startRecord = number;
      i++;
      var closed = false;
      while (i < length) {
        c = text.codeUnitAt(i);
        if (c == _quote) {
          if (i + 1 < length && text.codeUnitAt(i + 1) == _quote) {
            buffer.writeCharCode(_quote);
            i += 2;
            continue;
          }
          closed = true;
          i++;
          break;
        }
        // Delimiters and line breaks inside quotes belong to the field.
        buffer.writeCharCode(c);
        i++;
      }
      if (!closed) {
        errors.add(
          ImportRowError(
            startRecord,
            ImportErrorCode.unterminatedQuote,
            'A quoted field is never closed',
          ),
        );
        fields = <String>[];
        return CsvReadResult(records, errors);
      }
      // Anything after the closing quote up to the delimiter is literal.
      final tailStart = i;
      while (i < length) {
        c = text.codeUnitAt(i);
        if (c == delim || c == _cr || c == _lf) break;
        i++;
      }
      if (i > tailStart) buffer.write(text.substring(tailStart, i));
      fields.add(buffer.toString());
    } else {
      final start = i;
      while (i < length) {
        c = text.codeUnitAt(i);
        if (c == delim || c == _cr || c == _lf) break;
        i++;
      }
      fields.add(text.substring(start, i));
    }
    if (i >= length) {
      endRecord();
      break;
    }
    c = text.codeUnitAt(i);
    if (c == delim) {
      i++;
      if (i >= length) {
        fields.add('');
        endRecord();
      }
      continue;
    }
    // Line break.
    i++;
    if (c == _cr && i < length && text.codeUnitAt(i) == _lf) i++;
    endRecord();
  }
  return CsvReadResult(records, errors);
}
