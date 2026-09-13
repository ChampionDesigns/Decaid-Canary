# Example plugin guidance

This directory contains opt-in reference plugins. Keep each example small,
protocol-focused, and consistent with the host contracts documented in
[`doc/Plugins.md`](../../doc/Plugins.md). The Bookoo and Felicita examples are
reference implementations; preserve their notes and scope when adding another
example.

## Instance ownership

- `create()` must return an independent driver instance for one physical
  device. Every timer, subscription, pending read, callback, connection
  context, publication state, command state, and generation belongs to that
  instance.
- A plugin must support two physical devices with the same model or driver at
  the same time. Never key mutable state only by model, driver id, or a single
  module-level `active` value.
- Persisted settings and published data use the physical identity supplied by
  the host. Reconnecting or retiring one binding must not alter its sibling.

## Session and transport boundary

JavaScript owns protocol decoding and encoding, readiness, protocol timers,
validated device values, and plugin commands. Dart and the host own physical
I/O, discovery, BLE permissions, connection ownership, quotas, teardown,
reconnect, and publication enforcement. Use the host's existing transport and
session APIs; do not add a second BLE or settings authority in an example.

Capture the connect context and its generation in every asynchronous callback.
Before publishing, completing a command, or scheduling the next read, verify
that the instance and session are still current. A retired session must not
publish into a replacement session, report a failure for it, or send a stale
command. Retiring one binding must cancel only that binding's timers and
subscriptions; sibling bindings from the same plugin remain active. Unloading
a whole plugin generation retires all of its bindings, while bindings owned by
other plugins remain active.

## Future dosing controls

`DosingScaleController` from #834 is not merged into `main`. Do not describe it
as an existing production API or implement a speculative role map. When a
plugin integrates dosing controls, verify the live accepted design and exact
#834 compatibility contract, preserve its separate review boundary, and retain
the reserved dosing physical ID, external-dosing exclusion, and Bengle
integrated-scale ownership.

Role routing is explicit: circle tares only the originating currently assigned
scale role; square is a brewing-role action only, and does nothing for a dosing
role. Keep the documented machine-state, generation, identity, and GHC checks
at command dispatch and immediately before the machine write. There is no
sleeping start path and no retry against a replacement session.

## Required verification matrix

Write behavior tests before implementation and choose the smallest applicable
test tiers. Keep outside-in test-first ordering: start at public plugin/API
behavior, then cover multi-instance integration, then unit parsing and command
details.

For every plugin, cover zero, one, and two same-model instances; different
physical IDs; concurrent connections; per-instance state; disconnect,
reconnect, and binding retirement while a sibling stays active; stale
callbacks; permission revocation; quotas; and whole-plugin unload isolation.
Use deterministic fake GATT and two simulator instances where the host
boundary is under test. Add command, timer, settings, and publication cases
when the plugin declares those contracts, and report real hardware validation
separately.

When working on scale buttons or dosing, also cover brewing and dosing
reservations, circle-origin tare, brewing-only square routing, same-ID
reconnect, and queued machine replacement. When working on E64 sensors, also
cover two E64 instances alongside brewing/dosing scales and a milk probe.
