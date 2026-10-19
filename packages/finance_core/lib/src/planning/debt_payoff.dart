import 'package:meta/meta.dart';

import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';
import 'rounding.dart';

/// A loan's or card's interest rate and minimum repayment, entered by the
/// user and saved per account. The balance always comes from the ledger.
@immutable
class DebtTerms {
  DebtTerms({
    required this.id,
    required this.accountId,
    required this.annualRateBasisPoints,
    required this.minimumPayment,
  }) {
    _checkTerms(annualRateBasisPoints, minimumPayment);
  }

  final String id;

  /// The credit card or loan account.
  final String accountId;

  /// Annual interest rate in basis points (19.99% is 1999).
  final int annualRateBasisPoints;

  /// The minimum monthly repayment.
  final Money minimumPayment;
}

void _checkTerms(int rate, Money minimum) {
  if (rate < 0 || rate > 100000) {
    throw ArgumentError.value(rate, 'annualRateBasisPoints', 'not 0 to 100000');
  }
  if (!minimum.isPositive) {
    throw ArgumentError.value(minimum, 'minimumPayment', 'must be positive');
  }
}

/// One debt in a payoff comparison (BUD 06, P1).
@immutable
class PayoffDebt {
  PayoffDebt({
    required this.id,
    required this.name,
    required this.balance,
    required this.annualRateBasisPoints,
    required this.minimumPayment,
  }) {
    _checkTerms(annualRateBasisPoints, minimumPayment);
    if (balance.isNegative) {
      throw ArgumentError.value(balance, 'balance', 'must not be negative');
    }
    if (balance.currency != minimumPayment.currency) {
      throw CurrencyMismatchException(
        balance.currency,
        minimumPayment.currency,
      );
    }
  }

  final String id;
  final String name;

  /// Amount owed now, as a positive magnitude. Zero is already repaid.
  final Money balance;
  final int annualRateBasisPoints;
  final Money minimumPayment;
}

/// The order in which money beyond the minimums repays debts.
enum PayoffStrategy {
  /// Highest interest rate first (ties: smaller starting balance, then
  /// input order). Pays the least interest.
  avalanche,

  /// Smallest starting balance first (ties: higher rate, then input
  /// order). Clears accounts soonest.
  snowball,

  /// Only each debt's own minimum; no extra money and no rollover.
  minimumOnly,
}

/// One debt in one month of a payoff schedule.
@immutable
class DebtPayoffLine {
  const DebtPayoffLine({
    required this.debtId,
    required this.opening,
    required this.interest,
    required this.payment,
    required this.closing,
  });

  final String debtId;
  final Money opening;
  final Money interest;
  final Money payment;

  /// `opening + interest − payment`.
  final Money closing;
}

/// One monthly payment date of a payoff schedule.
@immutable
class DebtPayoffMonth {
  DebtPayoffMonth({
    required this.date,
    required List<DebtPayoffLine> lines,
    required this.totalPayment,
  }) : lines = List.unmodifiable(lines);

  final LocalDate date;

  /// Debts still owed at the start of the month, in input order.
  final List<DebtPayoffLine> lines;
  final Money totalPayment;
}

/// A month-by-month schedule for one strategy.
@immutable
class DebtPayoffPlan {
  DebtPayoffPlan({
    required this.strategy,
    required List<String> order,
    required List<DebtPayoffMonth> months,
    required this.totalInterest,
    required this.totalPaid,
    required Map<String, LocalDate?> payoffDates,
    required this.completed,
  }) : order = List.unmodifiable(order),
       months = List.unmodifiable(months),
       payoffDates = Map.unmodifiable(payoffDates);

  final PayoffStrategy strategy;

  /// Debt ids in the order extra money goes to them.
  final List<String> order;
  final List<DebtPayoffMonth> months;
  final Money totalInterest;
  final Money totalPaid;

  /// The payment date that clears each debt; null when it is already
  /// repaid at the start or never repaid within the schedule.
  final Map<String, LocalDate?> payoffDates;

  /// False when some debt is still owed after the maximum number of
  /// months (for example a minimum below the monthly interest).
  final bool completed;

  /// The last payoff date, when every debt is repaid.
  LocalDate? get debtFreeDate =>
      !completed || months.isEmpty ? null : months.last.date;
}

/// The three strategies side by side.
@immutable
class DebtPayoffComparison {
  const DebtPayoffComparison({
    required this.avalanche,
    required this.snowball,
    required this.minimumOnly,
  });

  final DebtPayoffPlan avalanche;
  final DebtPayoffPlan snowball;
  final DebtPayoffPlan minimumOnly;

  DebtPayoffPlan plan(PayoffStrategy strategy) => switch (strategy) {
    PayoffStrategy.avalanche => avalanche,
    PayoffStrategy.snowball => snowball,
    PayoffStrategy.minimumOnly => minimumOnly,
  };
}

/// Simulates repaying [debts] month by month (P1 debt payoff comparison).
///
/// Payments fall on [firstPaymentDate] and the same day of each later
/// month (clamped to shorter months). Each month, for every debt still
/// owed:
///
/// 1. Interest is the opening balance × annual rate ÷ 12, that is
///    `balance × basisPoints ÷ 120000`, rounded half away from zero to the
///    minor unit, and is added to the balance before the payment.
/// 2. The debt receives its minimum payment, or the whole balance when
///    that is smaller.
/// 3. For avalanche and snowball, the monthly budget is every debt's
///    minimum (including debts already repaid, so their minimums roll
///    over) plus [extraMonthly]; what remains after step 2 repays debts in
///    strategy order, each up to its balance. Minimum-only uses neither
///    the extra amount nor the rollover.
///
/// All arithmetic is exact in minor units. The schedule stops when every
/// debt is repaid or after [maxMonths] months.
DebtPayoffPlan simulateDebtPayoff({
  required List<PayoffDebt> debts,
  required PayoffStrategy strategy,
  required LocalDate firstPaymentDate,
  Money? extraMonthly,
  int maxMonths = 600,
}) {
  if (debts.isEmpty) throw ArgumentError.value(debts, 'debts', 'is empty');
  final currency = debts.first.balance.currency;
  for (final debt in debts) {
    if (debt.balance.currency != currency) {
      throw CurrencyMismatchException(currency, debt.balance.currency);
    }
  }
  if (extraMonthly != null) {
    if (extraMonthly.currency != currency) {
      throw CurrencyMismatchException(currency, extraMonthly.currency);
    }
    if (extraMonthly.isNegative) {
      throw ArgumentError.value(extraMonthly, 'extraMonthly', 'is negative');
    }
  }
  final indexes = List<int>.generate(debts.length, (i) => i);
  int compare(int a, int b, int Function(PayoffDebt, PayoffDebt) first) {
    final byFirst = first(debts[a], debts[b]);
    return byFirst != 0 ? byFirst : a.compareTo(b);
  }

  switch (strategy) {
    case PayoffStrategy.avalanche:
      indexes.sort(
        (a, b) => compare(a, b, (x, y) {
          final byRate = y.annualRateBasisPoints.compareTo(
            x.annualRateBasisPoints,
          );
          return byRate != 0 ? byRate : x.balance.compareTo(y.balance);
        }),
      );
    case PayoffStrategy.snowball:
      indexes.sort(
        (a, b) => compare(a, b, (x, y) {
          final byBalance = x.balance.compareTo(y.balance);
          return byBalance != 0
              ? byBalance
              : y.annualRateBasisPoints.compareTo(x.annualRateBasisPoints);
        }),
      );
    case PayoffStrategy.minimumOnly:
      break;
  }

  final balances = [for (final d in debts) d.balance.minor];
  final payoff = <String, LocalDate?>{for (final d in debts) d.id: null};
  final budget =
      debts.fold<int>(0, (sum, d) => sum + d.minimumPayment.minor) +
      (extraMonthly?.minor ?? 0);
  final months = <DebtPayoffMonth>[];
  var totalInterest = 0;
  var totalPaid = 0;
  Money money(int minor) => Money(minor, currency);

  while (balances.any((b) => b > 0) && months.length < maxMonths) {
    final date = firstPaymentDate.addMonths(
      months.length,
      intendedDay: firstPaymentDate.day,
    );
    final interest = List<int>.filled(debts.length, 0);
    final paid = List<int>.filled(debts.length, 0);
    var spent = 0;
    for (var i = 0; i < debts.length; i++) {
      if (balances[i] <= 0) continue;
      interest[i] = scaleHalfUp(
        balances[i],
        debts[i].annualRateBasisPoints,
        120000,
      );
      final due = balances[i] + interest[i];
      final minimum = debts[i].minimumPayment.minor;
      paid[i] = minimum < due ? minimum : due;
      spent += paid[i];
    }
    if (strategy != PayoffStrategy.minimumOnly) {
      var remaining = budget - spent;
      for (final i in indexes) {
        if (remaining <= 0) break;
        if (balances[i] <= 0) continue;
        final owing = balances[i] + interest[i] - paid[i];
        final more = remaining < owing ? remaining : owing;
        paid[i] += more;
        remaining -= more;
      }
    }
    final lines = <DebtPayoffLine>[];
    var monthTotal = 0;
    for (var i = 0; i < debts.length; i++) {
      if (balances[i] <= 0) continue;
      final closing = balances[i] + interest[i] - paid[i];
      lines.add(
        DebtPayoffLine(
          debtId: debts[i].id,
          opening: money(balances[i]),
          interest: money(interest[i]),
          payment: money(paid[i]),
          closing: money(closing),
        ),
      );
      if (closing == 0) payoff[debts[i].id] = date;
      balances[i] = closing;
      totalInterest += interest[i];
      monthTotal += paid[i];
    }
    totalPaid += monthTotal;
    months.add(
      DebtPayoffMonth(
        date: date,
        lines: lines,
        totalPayment: money(monthTotal),
      ),
    );
  }
  return DebtPayoffPlan(
    strategy: strategy,
    order: [for (final i in indexes) debts[i].id],
    months: months,
    totalInterest: money(totalInterest),
    totalPaid: money(totalPaid),
    payoffDates: payoff,
    completed: balances.every((b) => b <= 0),
  );
}

/// Runs [simulateDebtPayoff] for avalanche, snowball and minimum-only.
DebtPayoffComparison compareDebtPayoffs({
  required List<PayoffDebt> debts,
  required LocalDate firstPaymentDate,
  Money? extraMonthly,
  int maxMonths = 600,
}) {
  DebtPayoffPlan run(PayoffStrategy strategy) => simulateDebtPayoff(
    debts: debts,
    strategy: strategy,
    firstPaymentDate: firstPaymentDate,
    extraMonthly: extraMonthly,
    maxMonths: maxMonths,
  );
  return DebtPayoffComparison(
    avalanche: run(PayoffStrategy.avalanche),
    snowball: run(PayoffStrategy.snowball),
    minimumOnly: run(PayoffStrategy.minimumOnly),
  );
}

/// Payoff debts for the accounts in [terms], in the same order, using the
/// amount owed on [asOf] (all time when null). An account in credit counts
/// as owing nothing. Each debt's id is its account id.
List<PayoffDebt> payoffDebtsFromLedger(
  LedgerProjection ledger,
  Iterable<DebtTerms> terms, {
  LocalDate? asOf,
}) => [
  for (final t in terms)
    () {
      final owed = ledger.displayBalance(t.accountId, asOf: asOf);
      return PayoffDebt(
        id: t.accountId,
        name: ledger.chart.account(t.accountId).name,
        balance: owed.isNegative ? Money.zero(owed.currency) : owed,
        annualRateBasisPoints: t.annualRateBasisPoints,
        minimumPayment: t.minimumPayment,
      );
    }(),
];
