import 'package:meta/meta.dart';

import '../ledger/projection.dart';
import '../money/money.dart';
import '../time/local_date.dart';

/// Money held in an account and set aside for a goal or sinking fund
/// (BUD 05). Only [confirmed] reservations reserve anything; unconfirmed
/// ones are proposals.
@immutable
class Reservation {
  const Reservation({
    required this.id,
    required this.goalId,
    required this.accountId,
    required this.amount,
    this.confirmed = true,
  });

  final String id;
  final String goalId;
  final String accountId;
  final Money amount;
  final bool confirmed;
}

/// How much of a reservation is backed by money in its account.
@immutable
class ReservationFunding {
  const ReservationFunding(this.reservation, this.funded);

  final Reservation reservation;
  final Money funded;

  /// Reserved but not backed by money: an unfunded allocation.
  Money get unfunded => reservation.amount - funded;
  bool get isUnfunded => unfunded.isPositive;
}

/// Funding of confirmed reservations against account balances.
@immutable
class ReservationAssessment {
  ReservationAssessment(List<ReservationFunding> items, this.currency)
    : items = List.unmodifiable(items);

  final List<ReservationFunding> items;
  final Currency currency;

  Money get _zero => Money.zero(currency);

  ReservationFunding? funding(String reservationId) {
    for (final item in items) {
      if (item.reservation.id == reservationId) return item;
    }
    return null;
  }

  bool get hasUnfundedReservations => items.any((i) => i.isUnfunded);

  Money reservedInAccount(String accountId) => items
      .where((i) => i.reservation.accountId == accountId)
      .fold(_zero, (sum, i) => sum + i.reservation.amount);

  Money fundedForGoal(String goalId) => items
      .where((i) => i.reservation.goalId == goalId)
      .fold(_zero, (sum, i) => sum + i.funded);

  Money unfundedForGoal(String goalId) => items
      .where((i) => i.reservation.goalId == goalId)
      .fold(_zero, (sum, i) => sum + i.unfunded);

  /// Accounts whose reservations exceed the money held, with the excess.
  Map<String, Money> get overReservedByAccount {
    final result = <String, Money>{};
    for (final item in items.where((i) => i.isUnfunded)) {
      final id = item.reservation.accountId;
      result[id] = (result[id] ?? _zero) + item.unfunded;
    }
    return result;
  }
}

/// Funds confirmed [reservations] from each account's posted balance in the
/// order given, so a dollar is never reserved twice: once an account's
/// money is used up, later reservations against it are marked unfunded.
/// Money owed on a liability never funds a reservation.
ReservationAssessment assessReservations(
  Iterable<Reservation> reservations,
  LedgerProjection ledger, {
  LocalDate? asOf,
}) {
  final currency = ledger.chart.currency;
  final zero = Money.zero(currency);
  final available = <String, Money>{};
  final items = <ReservationFunding>[];
  for (final reservation in reservations.where((r) => r.confirmed)) {
    final id = reservation.accountId;
    final left = available.putIfAbsent(id, () {
      final account = ledger.chart.account(id);
      final balance = ledger.displayBalance(id, asOf: asOf);
      return account.type.isLiability || balance.isNegative ? zero : balance;
    });
    final funded = reservation.amount <= left ? reservation.amount : left;
    available[id] = left - funded;
    items.add(ReservationFunding(reservation, funded));
  }
  return ReservationAssessment(items, currency);
}
