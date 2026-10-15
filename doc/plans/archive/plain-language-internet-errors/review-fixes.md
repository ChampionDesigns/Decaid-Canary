# Internet Error Review Fixes

Deduplicate remote skin downloads at their shared storage entry point so Settings
Retry and manual update checks cannot install the same skins concurrently.
Preserve the existing updater interfaces and clear the in-flight future after
both success and failure.

Only explicitly user-facing validation errors may supply presentation text.
Parser failures receive a plain invalid-data message. Plugin manifest parsing
logs the original exception and stack trace while reporting a safe package error.
Known plugin downgrade guidance remains visible without changing REST statuses.

Add regression coverage before implementation, then run formatting, analysis,
focused tests and the full Flutter suite. Leave unrelated baseline failures alone.

## Verification

Six added regression tests cover parser diagnostics, malformed manifests, safe
persisted errors, downgrade guidance, shared download failures and retry, and
HTTP validation responses. The initial run reproduced all three review findings.
The final focused run passed 115 tests and analysis reported no issues. The full
suite finished with 4,845 passed, two skipped, and the same seven previously
verified Windows QuickJS/BigInt failures.

The isolated Windows test app returned the expected plain-language messages for
controlled malformed-data plugin and skin requests and an offline plugin request.
Their existing HTTP 400/500 statuses were preserved. Only simulated devices were
connected; the test app was stopped after verification. No tablet deployment,
commit, push, or PR was performed.
