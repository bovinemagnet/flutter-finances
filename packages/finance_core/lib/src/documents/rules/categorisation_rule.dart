import 'package:meta/meta.dart';

import '../../money/money.dart';
import '../imports/csv_parse.dart';
import '../text/normalise.dart';

/// Who decided an entry's category. Precedence, highest first: [user],
/// [rule], [suggestion]; [none] means nothing decided it yet (AUTO 01).
enum CategorySource { user, rule, suggestion, none }

/// What a rule is matched against.
@immutable
class RuleSubject {
  RuleSubject({
    this.merchant,
    this.description,
    this.accountId,
    this.amount,
    Set<String> tags = const {},
    this.currentCategoryId,
    this.categorySource = CategorySource.none,
  }) : tags = Set.unmodifiable(tags);

  /// The payee as entered or imported.
  final String? merchant;

  /// Statement description or notes.
  final String? description;
  final String? accountId;
  final Money? amount;
  final Set<String> tags;
  final String? currentCategoryId;
  final CategorySource categorySource;
}

/// A user's categorisation rule (AUTO 01). Every condition given must
/// hold:
///
/// - [merchant]: every word of its normalised merchant name (see
///   [normaliseMerchant]) is a word of the subject's normalised merchant.
/// - [descriptionContains]: its normalised text appears in the subject's
///   normalised description on word boundaries.
/// - [accountIds]: the subject's account is one of them.
/// - [minAmount], [maxAmount]: inclusive bounds on the amount's magnitude
///   in the same currency.
/// - [tags]: the subject has all of them.
///
/// Rules run in ascending [priority], ties broken by [id]; the first
/// matching enabled rule decides.
@immutable
class CategorisationRule {
  CategorisationRule({
    required this.id,
    required this.name,
    required this.categoryId,
    this.priority = 100,
    this.enabled = true,
    this.merchant,
    this.descriptionContains,
    Set<String> accountIds = const {},
    this.minAmount,
    this.maxAmount,
    Set<String> tags = const {},
  }) : accountIds = Set.unmodifiable(accountIds),
       tags = Set.unmodifiable(tags) {
    if (merchant == null &&
        descriptionContains == null &&
        accountIds.isEmpty &&
        minAmount == null &&
        maxAmount == null &&
        tags.isEmpty) {
      throw ArgumentError('A rule needs at least one condition');
    }
    if (minAmount != null && maxAmount != null && minAmount! > maxAmount!) {
      throw ArgumentError('The minimum amount is above the maximum');
    }
  }

  final String id;
  final String name;
  final String categoryId;
  final int priority;
  final bool enabled;
  final String? merchant;
  final String? descriptionContains;
  final Set<String> accountIds;
  final Money? minAmount;
  final Money? maxAmount;
  final Set<String> tags;

  bool matches(RuleSubject subject) {
    if (!enabled) return false;
    if (merchant != null) {
      final wanted = normaliseMerchant(merchant!).split(' ');
      final words = normaliseMerchant(subject.merchant ?? '')
          .split(' ')
          .toSet();
      if (!wanted.every(words.contains)) return false;
    }
    if (descriptionContains != null) {
      final needle = normaliseText(descriptionContains!);
      final haystack = normaliseText(subject.description ?? '');
      if (needle.isEmpty || !' $haystack '.contains(' $needle ')) return false;
    }
    if (accountIds.isNotEmpty && !accountIds.contains(subject.accountId)) {
      return false;
    }
    if (minAmount != null || maxAmount != null) {
      final amount = subject.amount?.abs();
      if (amount == null) return false;
      if (minAmount != null &&
          (amount.currency != minAmount!.currency || amount < minAmount!)) {
        return false;
      }
      if (maxAmount != null &&
          (amount.currency != maxAmount!.currency || amount > maxAmount!)) {
        return false;
      }
    }
    return subject.tags.containsAll(tags);
  }
}

@immutable
class CategoryDecision {
  const CategoryDecision(this.categoryId, this.source, {this.ruleId});

  final String categoryId;
  final CategorySource source;
  final String? ruleId;
}

/// Enabled rules in the order they are tried.
List<CategorisationRule> orderedRules(Iterable<CategorisationRule> rules) =>
    rules.where((r) => r.enabled).toList()..sort((a, b) {
      final byPriority = a.priority.compareTo(b.priority);
      return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
    });

/// The first matching rule, ignoring who categorised the subject.
CategorisationRule? firstMatchingRule(
  RuleSubject subject,
  Iterable<CategorisationRule> rules,
) {
  for (final rule in orderedRules(rules)) {
    if (rule.matches(subject)) return rule;
  }
  return null;
}

/// Decides a category with clear precedence (AUTO 01): an explicit user
/// category is kept; otherwise the first matching rule applies; otherwise
/// the general [suggestion]; otherwise null.
CategoryDecision? categorise(
  RuleSubject subject,
  Iterable<CategorisationRule> rules, {
  String? suggestion,
}) {
  final current = subject.currentCategoryId;
  if (subject.categorySource == CategorySource.user && current != null) {
    return CategoryDecision(current, CategorySource.user);
  }
  final rule = firstMatchingRule(subject, rules);
  if (rule != null) {
    return CategoryDecision(
      rule.categoryId,
      CategorySource.rule,
      ruleId: rule.id,
    );
  }
  if (suggestion != null) {
    return CategoryDecision(suggestion, CategorySource.suggestion);
  }
  return null;
}

/// A category chooser for import commits: the first matching rule for a
/// statement row on [accountId], using the description as both merchant
/// and description.
String? Function(ImportRow row) ruleCategoryChooser(
  Iterable<CategorisationRule> rules,
  String accountId,
) {
  final ordered = orderedRules(rules);
  return (row) {
    final subject = RuleSubject(
      merchant: row.description,
      description: row.description,
      accountId: accountId,
      amount: row.amount,
    );
    for (final rule in ordered) {
      if (rule.matches(subject)) return rule.categoryId;
    }
    return null;
  };
}
