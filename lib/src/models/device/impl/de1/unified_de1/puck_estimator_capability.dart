part of 'unified_de1.dart';

/// Decoded Bengle `0xA014` fused puck-estimator frames.
///
/// The transport subject is seeded with a ZERO-LENGTH frame, which
/// [parseBengleEstSample] rejects, so nothing is emitted until real `[T]` data
/// arrives. That is what lets a consumer treat "no event yet" as "this machine
/// has no estimator" rather than reading a run of zeros as real observations.
///
/// Serial/CDC only: the firmware does not register `0xA014` over BLE, so on a
/// BLE-connected Bengle this stream is silent by construction.
mixin PuckEstimatorCapability on UnifiedDe1 {
  Stream<BengleEstSample> get puckEstimator => _transport.estimator
      .map(parseBengleEstSample)
      .whereType<BengleEstSample>();
}
