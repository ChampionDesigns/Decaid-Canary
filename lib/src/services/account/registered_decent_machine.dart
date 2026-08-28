import 'dart:convert';

import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';

/// A machine registered to the linked Decent account, parsed from the support
/// API `sn` response (`onlyespressomachines=1&withskus=1`).
class RegisteredDecentMachine {
  final String serial;
  final String rawSku;

  /// DE1-family model parsed from the SKU. Null when the SKU format is not
  /// recognized — such records may still resolve an exact serial match but are
  /// never candidates for serial-0 auto/manual selection.
  final DecentMachineModel? recognizedModel;

  const RegisteredDecentMachine({
    required this.serial,
    this.rawSku = '',
    this.recognizedModel,
  });

  bool get isBengle => recognizedModel == DecentMachineModel.Bengle;

  bool get isLegacyDe1Candidate => recognizedModel != null && !isBengle;

  Map<String, dynamic> toJson() => {
    'serial': serial,
    'sku': rawSku,
    if (recognizedModel != null) 'model': recognizedModel!.name,
  };

  factory RegisteredDecentMachine.fromJson(Map<String, dynamic> json) {
    final serial = json['serial'];
    if (serial is! String || serial.isEmpty) {
      throw const FormatException('registered machine missing serial');
    }
    final modelName = json['model'];
    return RegisteredDecentMachine(
      serial: serial,
      rawSku: (json['sku'] as String?) ?? '',
      recognizedModel: modelName is String
          ? DecentMachineModel.values
                .where((m) => m.name == modelName)
                .firstOrNull
          : null,
    );
  }

  @override
  String toString() => 'RegisteredDecentMachine($serial, sku=$rawSku)';
}

/// Anchored, explicit DE1-family SKU model tokens, longest first so prefix
/// collisions (DE1XXXL vs DE1XL vs DE1) resolve to the most specific model.
const List<(String, DecentMachineModel)> _skuModelTokens = [
  ('DE1XXXL', DecentMachineModel.DE1XXXL),
  ('DE1XXL', DecentMachineModel.DE1XXL),
  ('DE1XL', DecentMachineModel.DE1XL),
  ('DE1CAFE', DecentMachineModel.DE1Cafe),
  ('DE1PRO', DecentMachineModel.DE1Pro),
  ('DE1PLUS', DecentMachineModel.DE1Plus),
  ('DE1+', DecentMachineModel.DE1Plus),
  ('BE1BENGLE', DecentMachineModel.Bengle),
  ('DE1', DecentMachineModel.DE1),
];

/// Parses the model from an explicit, anchored `DE-<model>` SKU token.
/// Returns null for unknown SKU formats — they are never guessed.
DecentMachineModel? parseSkuModel(String sku) {
  final upper = sku.toUpperCase();
  if (!upper.startsWith('DE-')) return null;
  final modelPart = upper.substring(3);
  if (modelPart.isEmpty) return null;
  for (final (token, model) in _skuModelTokens) {
    if (!modelPart.startsWith(token)) continue;
    if (_matchesAtTokenBoundary(modelPart, token)) return model;
  }
  return null;
}

/// True when [modelPart] starts with [token] and the token sits at a
/// boundary. The bare DE1 token must not swallow unknown longer variants
/// (DE1C..., DE1X...); those stay unknown instead of being guessed.
bool _matchesAtTokenBoundary(String modelPart, String token) {
  if (token != 'DE1') return true;
  final rest = modelPart.substring(token.length);
  return rest.isEmpty || !RegExp(r'[A-Z]').hasMatch(rest[0]);
}

/// Parses the support API machine-list body (`serial SKU` per line).
List<RegisteredDecentMachine> parseRegisteredMachines(String body) {
  final seen = <String>{};
  final machines = <RegisteredDecentMachine>[];
  for (final line in const LineSplitter().convert(body)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    final serial = parts.first;
    if (serial.isEmpty || !seen.add(serial)) continue;
    final sku = parts.length > 1 ? parts[1] : '';
    machines.add(
      RegisteredDecentMachine(
        serial: serial,
        rawSku: sku,
        recognizedModel: sku.isEmpty ? null : parseSkuModel(sku),
      ),
    );
  }
  return machines;
}
