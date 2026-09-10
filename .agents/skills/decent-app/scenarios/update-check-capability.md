# Scenario: update-check capability refusals

End-to-end check of `/ws/v1/update` `{"command":"check"}` on a build that does
not own its own app updates. Externally managed builds (App Store / TestFlight,
built with `--dart-define APP_STORE=true`) and macOS builds both refuse the
command with a direct `{"error", "url"}` reply instead of polling GitHub.

The refusal is the point: a check that cannot run must say so, rather than
settle back to `idle` and read as "up to date".

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale \
  --dart-define APP_STORE=true
BASE=http://localhost:8080
WS=ws://localhost:8080
```

## Connect frame reports no update and no install

```bash
websocat -n1 "$WS/ws/v1/update" \
  | jq '{phase, latestVersion, installable, releaseUrl, error}'
# {"phase":"idle","latestVersion":null,"installable":false,
#  "releaseUrl":"https://github.com/decentespresso/decaid/releases","error":null}
```

An externally managed build never reports an available update, so `releaseUrl`
is the releases page rather than a release tag.

## check is refused, and says why

The seeded snapshot arrives first, then the command reply:

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 | jq .
{"command":"check"}
CMD
# {"error":"App update checks are not supported on this build",
#  "url":"https://github.com/decentespresso/decaid/releases"}
```

One-shot assertion:

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 \
  | jq -e '(.error | contains("not supported")) and (.url | contains("releases"))'
{"command":"check"}
CMD
```

Exit 0 → the refusal reached the client. A hang, or a frame carrying `phase`,
is the regression this scenario exists to catch: the command was accepted and
silently no-opped.

## REST is unchanged

`GET /api/v1/update` exposes no capability field, so it returns the same
snapshot on a managed build as anywhere else:

```bash
curl -sf "$BASE/api/v1/update" | jq '{phase, latestVersion, installable}'
# {"phase":"idle","latestVersion":null,"installable":false}
```

## Control: an ordinary build still polls

```bash
scripts/sb-dev.sh stop
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
```

```bash
websocat --no-async-stdio -n -t --max-messages-rev 2 "$WS/ws/v1/update" <<'CMD' | tail -n1 | jq .
{"command":"check"}
CMD
```

Expect a state frame with `"phase":"checking"` — not an `{"error", "url"}`
reply. Whatever follows it depends on the network and on what is published:
`available`, `idle`, or `error` with `"error":"Update check failed: ..."`.
A state frame carries `phase` and `currentVersion`; a command refusal carries
only `error` and `url`.

## Postconditions

```bash
scripts/sb-dev.sh stop
```
