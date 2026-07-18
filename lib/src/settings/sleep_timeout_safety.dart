/// The machine's `InactivitySleepTimeout` is a THERMAL SAFETY NET, not a UI
/// preference. This file is the single source of truth for what the app is
/// allowed to write into it.
///
/// ## Why this exists (do not "simplify" it away)
///
/// The Bengle firmware sleeps itself after `InactivitySleepTimeout` minutes of
/// no interaction (the firmware inactivity check), which is the ONLY
/// thing that turns the heaters off when the tablet is gone — a dead battery, a
/// crashed app, a blackout. It is the machine's answer to the DE1 failure where
/// a machine whose tablet died stayed hot for days.
///
/// Two facts make writing `0` unacceptable:
///
///  1. **The firmware treats `<= 0` as "never sleep"** — the firmware:
///     the timer never runs. The timer simply never runs.
///  2. **The write STICKS.** The register is `PERM_RWD` (disk-backed); the MMR
///     write path persists it to firmware NVM, and
///     the firmware restores it at every boot. A `0` written
///     once survives every power cycle until something writes a non-zero value
///     back. And the machine boots HOT .
///
/// So an app that writes `0` leaves the machine **less safe than one that never
/// met the app at all** (the firmware's own default is 60 min). That is a
/// regression against doing nothing, and it is not a trade the user's sleep
/// preference is entitled to make.
///
/// The floor costs the user nothing: the firmware ignores this timer entirely
/// while a tablet is connected ("the tablet owns sleep"), so it only ever acts
/// once the tablet is already gone — precisely the case it exists for.
library;

/// The protective floor written when the user's setting would otherwise disable
/// the machine's safety net.
///
/// 60 minutes is the FIRMWARE'S OWN DEFAULT (`ModelIntParameters.def`:
/// `ENTRY(InactivitySleepTimeout, 60, 0, 240, 60, ...)`). Matching it means the
/// app can never make a machine less safe than a factory-fresh one.
const int kSafetySleepFloorMinutes = 60;

/// The firmware's accepted range for a timeout that actually runs. `0` is
/// rejected here on purpose: to the firmware `0` means "disabled", and that is
/// the one value the app must never send.
const int kMinMachineSleepTimeoutMinutes = 1;
const int kMaxSleepTimeoutMinutes = 240;

/// The `InactivitySleepTimeout` to write into the machine, in minutes.
/// **Guaranteed to be in `1..240` — never `0`, whatever the inputs.**
///
/// [userPresenceEnabled] is the "Auto sleep & wake" master toggle and
/// [userTimeoutMinutes] the visible dropdown value (where `0` reads
/// "Disabled").
///
/// Both of those govern *the app's* behaviour — whether the TABLET puts the
/// machine to sleep on its own idle timer. Neither may disable *the machine's*
/// last-resort thermal cut-out, so anything that would (`false`, `0`, a rogue
/// negative from the REST API or an imported settings blob) collapses to
/// [kSafetySleepFloorMinutes]. A positive user value is honoured as-is, merely
/// clamped into the range the firmware accepts.
int machineSleepTimeoutMinutes({
  required bool userPresenceEnabled,
  required int userTimeoutMinutes,
}) {
  // The master toggle off, or "Disabled" in the dropdown, means "the APP won't
  // sleep it". It does not — and must not — mean "the MACHINE won't sleep it".
  if (!userPresenceEnabled || userTimeoutMinutes <= 0) {
    return kSafetySleepFloorMinutes;
  }
  return userTimeoutMinutes.clamp(
    kMinMachineSleepTimeoutMinutes,
    kMaxSleepTimeoutMinutes,
  );
}

// ---------------------------------------------------------------------------
// Stored-preference bounds (from PR #457).
//
// Distinct concern from the machine-write floor above: this half decides what
// may be STORED as the user's preference (0 is a legal preference meaning
// "the app will not sleep the machine on its own idle timer"), and coerces
// untrusted input (REST JSON, imported settings blobs) instead of hard-casting
// it. The floor above still governs what is written TO the machine, so a
// stored 0 never reaches the firmware as "never sleep".
// ---------------------------------------------------------------------------

/// The widest range the stored user preference may take.
///
/// `0` is legal and means "Disabled" — the app will not sleep the machine on its
/// own idle timer. It is a statement about *the app's* behaviour only.
const int kMinSleepTimeoutSetting = 0;
const int kMaxSleepTimeoutSetting = kMaxSleepTimeoutMinutes;

/// True if [minutes] is a storable sleep-timeout preference (`0..240`).
bool isValidSleepTimeoutSetting(int minutes) =>
    minutes >= kMinSleepTimeoutSetting && minutes <= kMaxSleepTimeoutSetting;

/// Coerces an untrusted value (REST JSON, an imported settings blob) into a
/// storable sleep-timeout preference, or `null` if it is not a usable number at
/// all — so the caller can reject it rather than store garbage.
///
/// Note `0` survives this: it is a legal *preference*, not a rejection.
int? sanitizeSleepTimeoutSetting(Object? raw) {
  final int value;
  switch (raw) {
    case final int i:
      value = i;
    case final double d:
      value = d.round();
    case final String s:
      final parsed = int.tryParse(s.trim());
      if (parsed == null) return null;
      value = parsed;
    default:
      return null; // null, bool, list, … — not a timeout.
  }
  return value.clamp(kMinSleepTimeoutSetting, kMaxSleepTimeoutSetting);
}
