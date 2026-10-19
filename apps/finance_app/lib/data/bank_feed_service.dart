import 'package:finance_core/finance_core.dart';
import 'package:finance_store/finance_store.dart';

import '../features/transactions/transaction_form_model.dart';
import 'app_state.dart';

/// Turns bank feed proposals into entries the user has reviewed (BANK 02).
/// Nothing is posted until the user saves the pre-filled form.
class BankFeedService {
  BankFeedService({
    required this.state,
    required this.client,
    required this.pushChanges,
  });

  final AppState state;
  final BankFeedClient client;

  /// Uploads local changes, so the server knows the journal it is told
  /// about.
  final Future<void> Function() pushChanges;

  /// The journal id for a proposal, so the same transaction is never
  /// entered twice even when recording the decision has to be retried.
  static String journalIdFor(String recordId) =>
      ownedEntityId('bankFeedRecord', recordId);

  /// The entry already made from [proposal] on this device, if any.
  Journal? enteredFrom(BankProposal proposal) =>
      state.store.journal(journalIdFor(proposal.recordId));

  /// The pending entry a posted transaction completes, when the pending
  /// proposal it settles was accepted.
  Journal? pendingEntryFor(BankProposal proposal, List<BankProposal> all) {
    if (proposal.kind != BankProposalKind.settlesPending) return null;
    final related = all
        .where((p) => p.recordId == proposal.relatedRecordId)
        .firstOrNull;
    final journalId = related?.journalId;
    if (journalId == null) return null;
    final journal = state.store.journal(journalId);
    return journal?.status == JournalStatus.pending ? journal : null;
  }

  /// A form pre-filled from [proposal]; with [settling] it edits that
  /// pending entry instead of starting a new one.
  TransactionFormModel formFor(BankProposal proposal, {Journal? settling}) {
    final form = settling == null
        ? (TransactionFormModel(state.chart, today: state.today())
            ..type = proposal.isMoneyOut
                ? TransactionType.expense
                : TransactionType.income
            ..payee = proposal.description)
        : TransactionFormModel.fromJournal(
            state.chart,
            settling,
            today: state.today(),
          );
    return form
      ..amountText = Money(
        proposal.amountMinor.abs(),
        state.currency,
      ).toDecimalString()
      ..effectiveDate = LocalDate.parse(proposal.date)
      ..status = proposal.pending
          ? JournalStatus.pending
          : JournalStatus.posted;
  }

  /// Saves [draft] (once), uploads it and records the decision.
  Future<void> accept(
    String connectionId,
    BankProposal proposal,
    TransactionDraft draft, {
    Journal? settling,
  }) async {
    final journalId = settling?.id ?? journalIdFor(proposal.recordId);
    if (settling != null) {
      await state.correct(settling.id, draft);
    } else if (state.store.journal(journalId) == null) {
      await state.post(_withId(draft, journalId));
    }
    await _record(connectionId, proposal, journalId);
  }

  /// Records the decision for an entry already made from [proposal], after
  /// an earlier attempt could not reach the service.
  Future<void> finish(String connectionId, BankProposal proposal) =>
      _record(connectionId, proposal, journalIdFor(proposal.recordId));

  Future<void> _record(
    String connectionId,
    BankProposal proposal,
    String journalId,
  ) async {
    await pushChanges();
    await client.accept(connectionId, proposal.recordId, journalId: journalId);
  }

  Future<void> dismiss(String connectionId, BankProposal proposal) =>
      client.dismiss(connectionId, proposal.recordId);
}

TransactionDraft _withId(TransactionDraft draft, String id) => TransactionDraft(
  id: id,
  type: draft.type,
  accountId: draft.accountId,
  counterAccountId: draft.counterAccountId,
  amount: draft.amount,
  effectiveDate: draft.effectiveDate,
  splits: draft.splits,
  status: draft.status,
  payee: draft.payee,
  notes: draft.notes,
  tags: draft.tags,
  refundOf: draft.refundOf,
);
