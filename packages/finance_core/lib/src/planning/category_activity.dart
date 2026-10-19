import '../ledger/accounts.dart';
import '../ledger/journal.dart';
import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';

int _dateKey(LocalDate date) => date.year * 10000 + date.month * 100 + date.day;

/// Dated amounts for one key, sorted by date, with prefix sums so a range
/// total is two binary searches.
class _Series {
  final List<(int, int, String)> _raw = [];
  late final List<int> _dates;
  late final List<int> _prefix;
  late final List<String> _ids;

  void add(int date, int minor, String journalId) =>
      _raw.add((date, minor, journalId));

  void seal() {
    _raw.sort((a, b) => a.$1.compareTo(b.$1));
    _dates = [for (final e in _raw) e.$1];
    _ids = [for (final e in _raw) e.$3];
    _prefix = List<int>.filled(_raw.length + 1, 0);
    for (var i = 0; i < _raw.length; i++) {
      _prefix[i + 1] = _prefix[i] + _raw[i].$2;
    }
    _raw.clear();
  }

  int _lowerBound(int key) {
    var low = 0;
    var high = _dates.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_dates[mid] < key) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  (int, int) _range(LocalDate from, LocalDate to) =>
      (_lowerBound(_dateKey(from)), _lowerBound(_dateKey(to) + 1));

  int sum(LocalDate from, LocalDate to) {
    final (start, end) = _range(from, to);
    return _prefix[end] - _prefix[start];
  }

  bool any(LocalDate from, LocalDate to) {
    final (start, end) = _range(from, to);
    return end > start;
  }

  List<String> ids(LocalDate from, LocalDate to) {
    final (start, end) = _range(from, to);
    final seen = <String>{};
    return [
      for (var i = start; i < end; i++)
        if (seen.add(_ids[i])) _ids[i],
    ];
  }
}

/// Category and loan activity indexed by date, built in one pass over the
/// ledger so budget evaluation stays fast with 100,000 journals (NFR 09).
///
/// Figures follow [LedgerProjection.categoryNet]: posted and reversed
/// journals form the posted view, pending journals the pending view, and
/// income categories are negated so earning and spending are both positive.
class CategoryActivityIndex {
  CategoryActivityIndex._(this.currency);

  factory CategoryActivityIndex.fromLedger(LedgerProjection ledger) {
    final chart = ledger.chart;
    final index = CategoryActivityIndex._(chart.currency);
    for (final journal in ledger.journals) {
      final posted = journal.status.inPostedLedger;
      if (!posted && journal.status != JournalStatus.pending) continue;
      final day = _dateKey(journal.effectiveDate);
      final target = posted ? index._posted : index._pending;
      var ownedAccountsOnly = true;
      for (final posting in journal.postings) {
        final id = posting.ledgerAccountId;
        if (chart.hasCategory(id)) {
          final sign = chart.category(id).kind == CategoryKind.income ? -1 : 1;
          target
              .putIfAbsent(id, _Series.new)
              .add(day, sign * posting.amount.minor, journal.id);
        }
        if (!chart.hasAccount(id)) ownedAccountsOnly = false;
      }
      if (posted && ownedAccountsOnly) {
        for (final posting in journal.postings) {
          final id = posting.ledgerAccountId;
          if (chart.account(id).type == AccountType.loan) {
            index._principal
                .putIfAbsent(id, _Series.new)
                .add(day, posting.amount.minor, journal.id);
          }
        }
      }
    }
    for (final map in [index._posted, index._pending, index._principal]) {
      for (final series in map.values) {
        series.seal();
      }
    }
    return index;
  }

  final Currency currency;
  final Map<String, _Series> _posted = {};
  final Map<String, _Series> _pending = {};
  final Map<String, _Series> _principal = {};

  Map<String, _Series> _view(bool pending) => pending ? _pending : _posted;

  /// Net amount for a category in [from]..[to] inclusive.
  Money net(
    String categoryId,
    LocalDate from,
    LocalDate to, {
    bool pending = false,
  }) => Money(_view(pending)[categoryId]?.sum(from, to) ?? 0, currency);

  /// Source journals for [net], in date order without repeats.
  List<String> journalIds(
    String categoryId,
    LocalDate from,
    LocalDate to, {
    bool pending = false,
  }) => _view(pending)[categoryId]?.ids(from, to) ?? const [];

  /// Category ids with posted or pending activity in the range.
  Iterable<String> activeCategories(LocalDate from, LocalDate to) => {
    for (final entry in [..._posted.entries, ..._pending.entries])
      if (entry.value.any(from, to)) entry.key,
  };

  /// Principal repaid on a loan: postings to it from journals that only
  /// move money between owned accounts (transfers and their reversals).
  /// Interest and fees are categorised expenses and are not included.
  Money principalRepaid(String loanAccountId, LocalDate from, LocalDate to) =>
      Money(_principal[loanAccountId]?.sum(from, to) ?? 0, currency);

  List<String> principalJournalIds(
    String loanAccountId,
    LocalDate from,
    LocalDate to,
  ) => _principal[loanAccountId]?.ids(from, to) ?? const [];
}
