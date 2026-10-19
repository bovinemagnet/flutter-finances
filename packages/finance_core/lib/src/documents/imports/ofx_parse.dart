import 'dart:convert';
import 'dart:typed_data';

import '../../money/money.dart';
import '../../time/local_date.dart';
import 'csv_parse.dart';
import 'import_errors.dart';
import 'text_decoding.dart';

/// One bank or credit card statement read from an OFX file. It is a
/// [CsvParseResult], so its rows flow through `previewImport` and
/// `commitImport` exactly as CSV rows do; the statement details are extra.
class OfxParseResult extends CsvParseResult {
  OfxParseResult(
    super.rows,
    super.errors, {
    this.accountId,
    this.bankId,
    this.accountType,
    this.isCreditCard = false,
    this.currencyCode,
    this.ledgerBalance,
    this.ledgerBalanceDate,
    this.statementStart,
    this.statementEnd,
    List<String> otherAccountIds = const [],
  }) : otherAccountIds = List.unmodifiable(otherAccountIds);

  /// `ACCTID` of the statement's account.
  final String? accountId;

  /// `BANKID` (the BSB for Australian banks), when present.
  final String? bankId;

  /// `ACCTTYPE` of a bank statement, such as `CHECKING` or `SAVINGS`.
  final String? accountType;

  /// True for a `CCSTMTRS` credit card statement.
  final bool isCreditCard;

  /// `CURDEF`, the statement's default currency.
  final String? currencyCode;

  /// `LEDGERBAL/BALAMT`, signed as printed: negative on a credit card
  /// means money owed.
  final Money? ledgerBalance;
  final LocalDate? ledgerBalanceDate;

  /// `DTSTART` and `DTEND` of the transaction list.
  final LocalDate? statementStart;
  final LocalDate? statementEnd;

  /// Account ids of the other statements in the same file.
  final List<String> otherAccountIds;
}

/// Decodes OFX [bytes] and parses them with [parseOfx].
///
/// An OFX 1.x header naming `CHARSET:1252` (or `ISO-8859-1`) decodes as
/// Windows-1252; otherwise the encoding is detected (UTF-8 when valid).
OfxParseResult parseOfxBytes(
  Uint8List bytes,
  Currency currency, {
  String? accountId,
}) {
  final head = latin1
      .decode(Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, 1024)))
      .toUpperCase();
  final encoding = RegExp(r'CHARSET:\s*(1252|ISO-8859-1|8859-1)').hasMatch(head)
      ? TextEncoding.windows1252
      : detectEncoding(bytes);
  return parseOfx(decodeText(bytes, encoding), currency, accountId: accountId);
}

/// Parses an OFX 1.x (SGML) or 2.x (XML) bank or credit card statement
/// (IMP 01, P1).
///
/// Both syntaxes are read the same way: a tag followed by text is a value
/// (SGML leaves such elements unclosed) and closing tags close every open
/// element up to the matching one. XML character entities are decoded.
///
/// The statement is the first `STMTRS` or `CCSTMTRS`, or the one whose
/// `ACCTID` is [accountId]. Each `STMTTRN` becomes an [ImportRow]:
///
/// - `rowNumber` is the transaction's 1-based position in the statement.
/// - `date` is the first eight digits of `DTPOSTED` (`YYYYMMDD`, the
///   bank's local date); any time and zone are ignored.
/// - `amount` is `TRNAMT`, already signed from the account's point of
///   view (negative is money leaving, including card purchases). `.` is
///   the decimal separator, or `,` when the text has no `.`; trailing
///   zeros beyond the currency exponent are accepted.
/// - `description` is `NAME` (or `PAYEE/NAME`), followed by ` - MEMO` when
///   the memo is present and not already part of the name; the memo alone
///   when there is no name.
/// - `reference` is the trimmed `FITID`, so fingerprints use it (IMP 02).
/// - `raw` lists every value of the transaction as `PATH=value`.
///
/// Errors, at most one per transaction and in this order: `MISSING_FIELD`
/// (no `DTPOSTED`), `BAD_DATE`, `BAD_AMOUNT`, `MISSING_AMOUNT`,
/// `ZERO_AMOUNT`. Text without an `<OFX>` element, or without a statement,
/// reports `UNRECOGNISED_FORMAT` on row 0 (the file as a whole).
OfxParseResult parseOfx(String text, Currency currency, {String? accountId}) {
  final start = text.toUpperCase().indexOf('<OFX>');
  if (start < 0) return _unrecognised('The file is not an OFX statement');
  final root = _parseTree(text.substring(start));
  final statements = [
    for (final node in root.descendants())
      if (node.name == 'STMTRS' || node.name == 'CCSTMTRS') node,
  ];
  if (statements.isEmpty) {
    return _unrecognised('The OFX file has no bank or card statement');
  }
  String? idOf(_Node statement) =>
      statement.find('BANKACCTFROM')?.value('ACCTID') ??
      statement.find('CCACCTFROM')?.value('ACCTID');
  final statement = accountId == null
      ? statements.first
      : statements.firstWhere(
          (s) => idOf(s) == accountId,
          orElse: () => statements.first,
        );

  final rows = <ImportRow>[];
  final errors = <ImportRowError>[];
  var number = 0;
  for (final trn in statement.descendants()) {
    if (trn.name != 'STMTTRN') continue;
    number++;
    void fail(ImportErrorCode code, String message) =>
        errors.add(ImportRowError(number, code, message));

    final posted = trn.value('DTPOSTED');
    if (posted == null) {
      fail(ImportErrorCode.missingField, 'The transaction has no DTPOSTED');
      continue;
    }
    final date = _ofxDate(posted);
    if (date == null) {
      fail(ImportErrorCode.badDate, '"$posted" is not an OFX date');
      continue;
    }
    final amountText = trn.value('TRNAMT');
    final minor = amountText == null
        ? null
        : _ofxAmount(amountText, currency.exponent);
    if (amountText != null && minor == null) {
      fail(ImportErrorCode.badAmount, '"$amountText" is not an amount');
      continue;
    }
    if (minor == null) {
      fail(ImportErrorCode.missingAmount, 'The transaction has no TRNAMT');
      continue;
    }
    if (minor == 0) {
      fail(ImportErrorCode.zeroAmount, 'The amount is zero');
      continue;
    }
    final reference = trn.value('FITID')?.trim() ?? '';
    rows.add(
      ImportRow(
        rowNumber: number,
        date: date,
        amount: Money(minor, currency),
        description: joinNameAndMemo(
          trn.value('NAME') ?? trn.find('PAYEE')?.value('NAME'),
          trn.value('MEMO'),
        ),
        reference: reference.isEmpty ? null : reference,
        raw: trn.leafValues(),
      ),
    );
  }

  final ledger = statement.find('LEDGERBAL');
  final balanceText = ledger?.value('BALAMT');
  final balance = balanceText == null
      ? null
      : _ofxAmount(balanceText, currency.exponent);
  final list = statement.find('BANKTRANLIST');
  LocalDate? date(String? text) => text == null ? null : _ofxDate(text);
  final account = statement.find('BANKACCTFROM');
  final thisId = idOf(statement);
  return OfxParseResult(
    rows,
    errors,
    accountId: thisId,
    bankId: account?.value('BANKID'),
    accountType: account?.value('ACCTTYPE'),
    isCreditCard: statement.name == 'CCSTMTRS',
    currencyCode: statement.value('CURDEF'),
    ledgerBalance: balance == null ? null : Money(balance, currency),
    ledgerBalanceDate: date(ledger?.value('DTASOF')),
    statementStart: date(list?.value('DTSTART')),
    statementEnd: date(list?.value('DTEND')),
    otherAccountIds: [
      for (final s in statements)
        if (!identical(s, statement) && idOf(s) != null) idOf(s)!,
    ],
  );
}

OfxParseResult _unrecognised(String message) => OfxParseResult(const [], [
  ImportRowError(0, ImportErrorCode.unrecognisedFormat, message),
]);

/// Joins a payee name and a memo into one description: the name, then
/// ` - memo` unless the memo is empty or already contained in the name
/// (ignoring case); the memo alone when there is no name.
String joinNameAndMemo(String? name, String? memo) {
  final n = name?.trim() ?? '';
  final m = memo?.trim() ?? '';
  if (n.isEmpty) return m;
  if (m.isEmpty || n.toLowerCase().contains(m.toLowerCase())) return n;
  return '$n - $m';
}

LocalDate? _ofxDate(String text) {
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})').firstMatch(text.trim());
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (month < 1 || month > 12 || day < 1) return null;
  if (day > LocalDate.daysInMonth(year, month)) return null;
  return LocalDate(year, month, day);
}

int? _ofxAmount(String text, int exponent) {
  var t = text.trim();
  final separator = !t.contains('.') && t.contains(',') ? ',' : '.';
  final point = t.indexOf(separator);
  if (point >= 0) {
    final fraction = t.substring(point + 1);
    if (fraction.length > exponent &&
        RegExp(r'^0+$').hasMatch(fraction.substring(exponent))) {
      t = t.substring(0, point + 1 + exponent);
    }
  }
  final parsed = parseCsvAmount(t, exponent, decimalSeparator: separator);
  return parsed.isBad ? null : parsed.minor;
}

// A minimal OFX element tree --------------------------------------------

class _Node {
  _Node(this.name);

  final String name;
  String? text;
  final children = <_Node>[];

  Iterable<_Node> descendants() sync* {
    for (final child in children) {
      yield child;
      yield* child.descendants();
    }
  }

  /// The first descendant named [name].
  _Node? find(String name) {
    for (final node in descendants()) {
      if (node.name == name) return node;
    }
    return null;
  }

  /// The text of the direct child named [name].
  String? value(String name) {
    for (final child in children) {
      if (child.name == name) return child.text;
    }
    return null;
  }

  List<String> leafValues([String prefix = '']) => [
    for (final child in children)
      if (child.children.isEmpty)
        '$prefix${child.name}=${child.text ?? ''}'
      else
        ...child.leafValues('$prefix${child.name}.'),
  ];
}

final _tag = RegExp(r'<(/?)([A-Za-z0-9_.]+)[^>]*?(/?)>');

_Node _parseTree(String text) {
  final root = _Node('');
  final stack = [root];
  var last = 0;
  for (final match in _tag.allMatches(text)) {
    final between = text.substring(last, match.start).trim();
    last = match.end;
    final top = stack.last;
    if (between.isNotEmpty &&
        stack.length > 1 &&
        top.children.isEmpty &&
        top.text == null) {
      // An element followed by text is a value; SGML never closes it.
      top.text = _decodeEntities(between);
      stack.removeLast();
    }
    final name = match[2]!.toUpperCase();
    if (match[1] == '/') {
      final index = stack.lastIndexWhere((n) => n.name == name);
      if (index > 0) stack.removeRange(index, stack.length);
      continue;
    }
    final node = _Node(name);
    stack.last.children.add(node);
    if (match[3] != '/') stack.add(node);
  }
  return root;
}

String _decodeEntities(String text) => text.replaceAllMapped(
  RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos|nbsp);'),
  (m) {
    final entity = m[1]!;
    if (entity.startsWith('#x')) {
      return String.fromCharCode(int.parse(entity.substring(2), radix: 16));
    }
    if (entity.startsWith('#')) {
      return String.fromCharCode(int.parse(entity.substring(1)));
    }
    return const {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'nbsp': ' ',
    }[entity]!;
  },
);
