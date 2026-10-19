import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../data/oidc.dart';
import '../capabilities.dart';

/// Desktop builds receive the redirect on a loopback port; mobile builds use
/// the application's own URL scheme through the system browser session.
const desktopRedirectPort = 43823;
const mobileRedirectScheme = 'com.paulsnow.finance.app';

String redirectUriFor(PlatformCapabilities capabilities) => capabilities.isDesktop
    ? 'http://localhost:$desktopRedirectPort/callback'
    : '$mobileRedirectScheme:/oauth';

/// Runs the browser part of sign-in and completes the session.
Future<void> signInWithBrowser(
    OidcSession session, PlatformCapabilities capabilities) async {
  final request = await session.authorisationRequest();
  final callback = await FlutterWebAuth2.authenticate(
    url: request.uri.toString(),
    callbackUrlScheme: capabilities.isDesktop
        ? 'http://localhost:$desktopRedirectPort'
        : mobileRedirectScheme,
  );
  await session.completeSignIn(request, callback);
}
