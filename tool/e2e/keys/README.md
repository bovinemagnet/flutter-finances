# Test-only signing keys

**These keys are for local end-to-end tests only. They are public, so they
must never be used to sign or verify anything outside `tool/e2e/run.sh`.**

- `test-only-private.pem` (PKCS #8) signs the RS256 access tokens that the
  Dart end-to-end tests in `packages/finance_store/test/e2e/` send.
- `test-only-public.pem` is what the server's `e2e` profile verifies those
  tokens with (`spring.security.oauth2.resourceserver.jwt.public-key-location`),
  instead of contacting an OIDC issuer.

The `e2e` profile refuses to start unless `FINANCE_E2E_PUBLIC_KEY` names a
key explicitly, so no other profile or deployment picks these keys up by
accident. Never configure a real environment with them.

To replace them:

```sh
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out test-only-private.pem
openssl pkey -in test-only-private.pem -pubout -out test-only-public.pem
```
