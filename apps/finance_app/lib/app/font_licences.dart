import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bundled fonts and their SIL Open Font Licence files.
const fontLicences = {
  'Inter': 'assets/fonts/OFL-Inter.txt',
  'JetBrains Mono': 'assets/fonts/OFL-JetBrainsMono.txt',
  'Space Grotesk': 'assets/fonts/OFL-SpaceGrotesk.txt',
};

/// Adds the bundled fonts' licences to the licences page.
void registerFontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry(key: family, value: path) in fontLicences.entries) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString(path));
    }
  });
}
