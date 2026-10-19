final _nonAlphanumeric = RegExp(r'[^a-z0-9]+');
final _digit = RegExp(r'\d');

/// Normalises free text for comparison and fingerprints.
///
/// Lower-cases the text, replaces every run of characters other than ASCII
/// `a`-`z` and `0`-`9` with one space, and trims. Non-ASCII letters become
/// separators, so `Café` normalises to `caf`. This rule is part of the
/// shared fixture contract (`csv.fingerprint`).
String normaliseText(String text) =>
    text.toLowerCase().replaceAll(_nonAlphanumeric, ' ').trim();

/// Words that say nothing about who the merchant is: legal suffixes,
/// payment processors and channels, web domains and Australian locations.
const merchantNoiseWords = {
  'pty', 'ltd', 'limited', 'co', 'inc', 'the', //
  'au', 'aus', 'australia', 'nsw', 'vic', 'qld', 'wa', 'sa', 'tas', 'act',
  'nt', 'www', 'com', 'net', 'org', //
  'visa', 'mastercard', 'purchase', 'eftpos', 'pos', 'card', 'debit',
  'credit', 'tap', 'contactless', 'sq', 'sp', 'pp', 'paypal', 'sumup',
};

/// Normalises a merchant name for matching (MATCH 01, AUTO 01).
///
/// Applies [normaliseText], then drops [merchantNoiseWords] and any word
/// containing a digit (store numbers, card digits, dates). Falls back to
/// [normaliseText] when nothing would remain.
String normaliseMerchant(String text) {
  final plain = normaliseText(text);
  final kept = plain
      .split(' ')
      .where(
        (w) =>
            w.isNotEmpty &&
            !merchantNoiseWords.contains(w) &&
            !_digit.hasMatch(w),
      )
      .join(' ');
  return kept.isEmpty ? plain : kept;
}

/// A similarity between 0 and 1 for two merchant names.
///
/// 1 when the normalised names are equal; 0.9 when every word of one name
/// appears in the other; at least 0.8 when both start with the same word of
/// four or more letters; otherwise the Dice coefficient of character
/// bigrams. This is a ranking aid, never a probability.
double merchantSimilarity(String a, String b) {
  final na = normaliseMerchant(a);
  final nb = normaliseMerchant(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;
  final wa = na.split(' ').toSet();
  final wb = nb.split(' ').toSet();
  if (wa.every(wb.contains) || wb.every(wa.contains)) return 0.9;
  final dice = _dice(na.replaceAll(' ', ''), nb.replaceAll(' ', ''));
  final firstA = na.split(' ').first;
  if (firstA.length >= 4 && firstA == nb.split(' ').first) {
    return dice > 0.8 ? dice : 0.8;
  }
  return dice;
}

double _dice(String a, String b) {
  if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
  final bigrams = <String, int>{};
  for (var i = 0; i < a.length - 1; i++) {
    final gram = a.substring(i, i + 2);
    bigrams[gram] = (bigrams[gram] ?? 0) + 1;
  }
  var shared = 0;
  for (var i = 0; i < b.length - 1; i++) {
    final gram = b.substring(i, i + 2);
    final count = bigrams[gram] ?? 0;
    if (count > 0) {
      shared++;
      bigrams[gram] = count - 1;
    }
  }
  return 2 * shared / (a.length - 1 + b.length - 1);
}
