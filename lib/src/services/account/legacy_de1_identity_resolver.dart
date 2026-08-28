import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/services/account/registered_decent_machine.dart';

/// Outcome of a legacy DE1 identity resolution attempt.
sealed class LegacyDe1IdentityResolution {
  const LegacyDe1IdentityResolution();
}

final class ResolvedLegacyDe1Identity extends LegacyDe1IdentityResolution {
  const ResolvedLegacyDe1Identity(this.machine);

  final RegisteredDecentMachine machine;
}

final class AmbiguousLegacyDe1Identity extends LegacyDe1IdentityResolution {
  const AmbiguousLegacyDe1Identity(this.candidates);

  /// Plausible registered legacy DE1-family machines for manual selection.
  final List<RegisteredDecentMachine> candidates;
}

final class UnavailableLegacyDe1Identity extends LegacyDe1IdentityResolution {
  const UnavailableLegacyDe1Identity();
}

/// Pure resolution of a legacy DE1 machine's identity from the linked
/// account's registered machines. No account, storage, or UI dependencies.
class LegacyDe1IdentityResolver {
  const LegacyDe1IdentityResolver();

  /// Resolves the effective identity for a machine reporting [rawSerial]
  /// (raw MMR `SerialN`) with raw [rawModelValue] (raw MMR `v13Model`).
  ///
  /// A nonzero [rawSerial] resolves only on an exact match against a
  /// non-Bengle registered record. A `0` serial uses the validated persisted
  /// mapping first, then auto-selects a single known legacy candidate or
  /// narrows multiple candidates with the raw model hint, and finally falls
  /// back to an ambiguous manual-selection request.
  LegacyDe1IdentityResolution resolve({
    required String rawSerial,
    required int rawModelValue,
    required List<RegisteredDecentMachine> registeredMachines,
    RegisteredDecentMachine? mappedMachine,
  }) {
    if (rawSerial.isNotEmpty && rawSerial != '0') {
      final match = registeredMachines
          .where((m) => m.serial == rawSerial && !m.isBengle)
          .firstOrNull;
      if (match != null) return ResolvedLegacyDe1Identity(match);
      return const UnavailableLegacyDe1Identity();
    }

    final mappedSerial = mappedMachine?.serial;
    if (mappedMachine != null &&
        !mappedMachine.isBengle &&
        mappedSerial != null &&
        registeredMachines.any((m) => m.serial == mappedSerial)) {
      return ResolvedLegacyDe1Identity(mappedMachine);
    }

    final candidates = registeredMachines
        .where((m) => m.isLegacyDe1Candidate)
        .toList();
    if (candidates.length == 1) {
      return ResolvedLegacyDe1Identity(candidates.single);
    }
    if (candidates.length > 1) {
      final rawModel = DecentMachineModel.fromInt(rawModelValue);
      if (rawModel != DecentMachineModel.Unknown &&
          rawModel != DecentMachineModel.Bengle) {
        final hinted = candidates
            .where((m) => m.recognizedModel == rawModel)
            .toList();
        if (hinted.length == 1) {
          return ResolvedLegacyDe1Identity(hinted.single);
        }
      }
      return AmbiguousLegacyDe1Identity(candidates);
    }
    return const UnavailableLegacyDe1Identity();
  }
}
