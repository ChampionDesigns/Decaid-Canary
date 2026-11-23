abstract interface class RawProfileWriteCounter {
  int get rawProfileWrites;
}

int rawProfileWritesOf(Object? machine) =>
    machine is RawProfileWriteCounter ? machine.rawProfileWrites : 0;
