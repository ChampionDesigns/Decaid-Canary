import 'package:reaprime/src/models/data/native_shaping.dart';

abstract interface class NativeShapingReporter {
  NativeShapingReport? get lastNativeShapingReport;
}

NativeShapingReport? nativeShapingReportedBy(Object? machine) =>
    machine is NativeShapingReporter ? machine.lastNativeShapingReport : null;
