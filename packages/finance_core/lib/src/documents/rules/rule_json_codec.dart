import '../../money/money.dart';
import 'categorisation_rule.dart';
import 'rule_application.dart';

/// JSON formats for rules and rule undo records.

Map<String, Object?> categorisationRuleToJson(CategorisationRule rule) => {
  'id': rule.id,
  'name': rule.name,
  'categoryId': rule.categoryId,
  'priority': rule.priority,
  'enabled': rule.enabled,
  'merchant': rule.merchant,
  'descriptionContains': rule.descriptionContains,
  'accountIds': rule.accountIds.toList()..sort(),
  'minAmountMinor': rule.minAmount?.minor,
  'maxAmountMinor': rule.maxAmount?.minor,
  'currency': (rule.minAmount ?? rule.maxAmount)?.currency.code,
  'tags': rule.tags.toList()..sort(),
};

/// Reads a rule whose amounts are in the workspace [currency].
CategorisationRule categorisationRuleFromJson(
  Map<String, Object?> json,
  Currency currency,
) {
  final code = json['currency'] as String?;
  if (code != null && code != currency.code) {
    throw CurrencyMismatchException(
      currency,
      Currency(code, currency.exponent),
    );
  }
  Money? money(Object? minor) =>
      minor == null ? null : Money(minor as int, currency);
  return CategorisationRule(
    id: json['id'] as String,
    name: json['name'] as String,
    categoryId: json['categoryId'] as String,
    priority: json['priority'] as int? ?? 100,
    enabled: json['enabled'] as bool? ?? true,
    merchant: json['merchant'] as String?,
    descriptionContains: json['descriptionContains'] as String?,
    accountIds: {...(json['accountIds'] as List? ?? const []).cast<String>()},
    minAmount: money(json['minAmountMinor']),
    maxAmount: money(json['maxAmountMinor']),
    tags: {...(json['tags'] as List? ?? const []).cast<String>()},
  );
}

Map<String, Object?> ruleUndoRecordToJson(RuleUndoRecord record) => {
  'id': record.id,
  'appliedAt': record.appliedAt.toUtc().toIso8601String(),
  'entries': [
    for (final e in record.entries)
      {
        'originalJournalId': e.originalJournalId,
        'newJournalId': e.newJournalId,
        'previousCategoryId': e.previousCategoryId,
        'newCategoryId': e.newCategoryId,
        'previousSource': e.previousSource.name,
        'ruleId': e.ruleId,
        'inPlace': e.inPlace,
      },
  ],
};

RuleUndoRecord ruleUndoRecordFromJson(Map<String, Object?> json) =>
    RuleUndoRecord(
      id: json['id'] as String,
      appliedAt: DateTime.parse(json['appliedAt'] as String).toUtc(),
      entries: [
        for (final e in (json['entries'] as List).cast<Map<String, Object?>>())
          RuleUndoEntry(
            originalJournalId: e['originalJournalId'] as String,
            newJournalId: e['newJournalId'] as String,
            previousCategoryId: e['previousCategoryId'] as String,
            newCategoryId: e['newCategoryId'] as String,
            previousSource: CategorySource.values.byName(
              e['previousSource'] as String,
            ),
            ruleId: e['ruleId'] as String,
            inPlace: e['inPlace'] as bool,
          ),
      ],
    );
