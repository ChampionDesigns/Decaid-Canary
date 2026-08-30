# Scenario: machine settings write verification

End-to-end check of `POST /api/v1/machine/settings`. The route still answers `202`, and the body
now carries a per-field verdict read back from the machine inside the same serialized device
write: `applied`, `adjusted` (with the value the machine actually holds), or `unverified` when the
read-back itself failed.

The `fan` field is the interesting one: `MMRItem.fanThreshold` is bounded `0..50`, so a request of
`51` is clamped on the way out and the machine keeps `50`. That drop used to be silent.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
BASE=http://localhost:8080
```

## A field with no bounds reports applied

```bash
curl -sf -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' \
  -d '{"steamPurgeMode": 1}' | jq -e '.results.steamPurgeMode.status == "applied"'
# true
```

## An out-of-band fan write reports adjusted, with the value the machine holds

```bash
curl -sf -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' \
  -d '{"fan": 51}' | jq '.results.fan'
# {"requested": 51, "actual": 50, "status": "adjusted"}

curl -sf -o /dev/null -w '%{http_code}\n' -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' -d '{"fan": 51}'
# 202 — the status code is unchanged; the verdict lives in the body
```

## Per-field localisation within one body

```bash
curl -sf -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' \
  -d '{"fan": 51, "steamPurgeMode": 1}' \
  | jq -e '.results.fan.status == "adjusted" and .results.steamPurgeMode.status == "applied"'
# true
```

## An in-band fan write reports applied and survives a re-read

```bash
curl -sf -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' \
  -d '{"fan": 45}' | jq -e '.results.fan.status == "applied" and .results.fan.actual == 45'
# true

curl -sf "$BASE/api/v1/machine/settings" | jq -e '.fan == 45'
# true
```

## An empty body is accepted with an empty report

```bash
curl -sf -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' -d '{}' | jq -e '.results == {}'
# true
```

## Existing failure modes are unchanged

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/api/v1/machine/settings" \
  -H 'content-type: application/json' -d '{not json'
# 400
```

## Postconditions

```bash
scripts/sb-dev.sh stop
```
