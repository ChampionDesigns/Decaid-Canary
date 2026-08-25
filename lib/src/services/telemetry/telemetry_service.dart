import 'package:reaprime/src/services/telemetry/noop_telemetry_service.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';

abstract class TelemetryService {
  Future<void> initialize();

  Future<void> recordError(
    Object error,
    StackTrace? stackTrace, {
    bool fatal = false,
  });

  Future<void> log(String message);

  Future<void> setCustomKey(String key, Object value);

  Future<void> recordTrace(String name, Map<String, int> metrics);

  Future<void> setConsentEnabled(bool enabled);

  String getLogBuffer();

  // Decaid-Canary fork: no upstream Firebase project; telemetry is disabled.
  static TelemetryService create({required LogBuffer logBuffer}) {
    return NoOpTelemetryService();
  }
}
