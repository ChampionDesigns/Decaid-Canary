abstract interface class De1EmulationReporter {
  bool get lastUploadedProfileDe1Emulation;
}

bool de1EmulationSentBy(Object? machine) =>
    machine is De1EmulationReporter && machine.lastUploadedProfileDe1Emulation;
