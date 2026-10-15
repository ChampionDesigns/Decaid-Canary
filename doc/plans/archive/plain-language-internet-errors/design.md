# Plain-Language Internet Errors

## Design

Internet-dependent actions must explain failures without displaying transport
exceptions, internal URLs, or stack traces. A shared type-based formatter gives
action-specific connection, timeout, secure-connection, validation, and storage
messages. Original exceptions and stack traces remain in existing diagnostic
logs. No connectivity probe, dependency, automatic retry, or trust exception is
introduced.

Native skin and plugin installs and updates, app updates, feedback, and the
host-owned online proxies use these messages. Existing account/onboarding
messages, upstream HTTP responses, and streaming passthrough remain unchanged.

Batch updates retain their Future<void> interfaces and in-flight deduplication.
They finish all items and report an immutable RemoteUpdateException containing
the attempted count and item/error pairs. Failed and partial manual checks use
warning messages and existing API HTTP 500 envelopes, not false success.
Background checks stay quiet and installed content remains usable offline.

Retry is manual, keeps the original parameters, prevents concurrent attempts,
and checks widget lifetime. Plugin approval checks still run on every attempt.
Feedback retains its form and never retries known-successful submissions.

Permission review is checked against the current pending version, release or
commit, and requested permissions immediately before installation. A candidate
that changes while its dialog is open requires a new review, including on Retry.

## Verification

Verified on Windows with Flutter 3.47.5: formatting completed, analysis reported
no issues, and 83 focused tests passed. The full suite finished with 4,839 passed,
two skipped, and seven JavaScript-runtime BigInt failures. The same seven failures
were reproduced from an unchanged revision using the same native runtime.

The isolated Windows test runner was hot-restarted with the current Dart sources
and a temporary offline HTTP client. Eight online-action REST checks returned
plain-language HTTP 500 errors. App-update REST and WebSocket state carried the
same friendly connection message. Native widget tests covered retained inputs,
manual retry, duplicate attempts, disposal, partial results, and permission review.
No tablet installation or physical machine functions were performed.
