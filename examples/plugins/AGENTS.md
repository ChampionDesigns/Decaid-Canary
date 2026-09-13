# Example plugin guidance

This directory contains opt-in reference plugins. Keep each example small,
protocol-focused, and consistent with the host contracts documented in
[`doc/Plugins.md`](../../doc/Plugins.md). The Bookoo and Felicita examples are
reference implementations; preserve their notes and scope when adding another
example.

## Instance ownership

- For BLE drivers, `create()` must return an independent driver instance for
  one physical device. Every timer, subscription, pending read, callback,
  connection context, publication state, command state, and generation belongs
  to that instance. Sensor registrations use the same per-instance ownership
  rule in their `onLoad` and registration state.
- A single-device stage must still keep one physical instance's state isolated
  and reject a second binding under the existing device quota. When concurrent
  same-model support is introduced, the plugin must support two physical
  devices at the same time. Never key mutable state only by model, driver id,
  or a single module-level `active` value.
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

## Dosing controls

The proposed `DosingScaleController` contract and its
`/api/v1/scale/dosing/*` routes are tracked in draft PR #834 and the guarded
actions draft #845; they are not asserted as current upstream APIs. Before
integrating dosing controls, verify the live accepted design and exact branch
contract. Retain the reserved dosing physical ID, external-dosing exclusion,
and Bengle integrated-scale ownership, and keep dosing publication separate
from the brewing scale.

Role routing is explicit: circle tares only the originating currently assigned
scale role; square is a brewing-role action only, and does nothing for a dosing
role. Keep the documented machine-state, generation, identity, and GHC checks
at command dispatch and immediately before the machine write. There is no
sleeping start path and no retry against a replacement session.

## Required verification matrix

Write behavior tests before implementation and choose the smallest applicable
test tiers. Keep outside-in test-first ordering: start at public plugin/API
behavior, then cover instance integration when concurrent support is
introduced, then unit parsing and command details.

For an initial single-device stage, cover zero and one instance, a second
binding rejected under the existing quota, the physical ID, per-instance
state, disconnect, reconnect, stale callbacks, permission revocation, and
whole-plugin unload isolation. When concurrent same-model support is added,
expand the matrix to two physical IDs, concurrent connections, and retirement
of one binding while its sibling stays active. Use deterministic fake GATT and
two simulator instances only when the host boundary supports that concurrent
case. Add command, timer, settings, and publication cases when the plugin
declares those contracts, and report real hardware validation separately.

When working on scale buttons, cover circle-origin tare, brewing-only square
routing, same-ID reconnect, and queued machine replacement. When integrating
dosing, also cover brewing and dosing reservations and the dosing-role tare
and square exclusions. When working on E64 sensors, also cover two E64
instances alongside brewing/dosing scales and a milk probe.

For per-device plugin settings, draft PR #849 proposes declaring a driver
`settingsEndpoint` that names an `api` HTTP endpoint. Verify the live accepted
branch contract before relying on it. When available, the native Device
Management page routes that action to `/api/v1/plugins/:id/:endpoint` with
`ui=1`, `deviceId`, and `deviceName`; the page uses `url_launcher` with
`LaunchMode.inAppBrowserView`, while the plugin owns validation and persistence.
