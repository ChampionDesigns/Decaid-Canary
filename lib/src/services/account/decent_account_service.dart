import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'registered_decent_machine.dart';

List<String> parseSerialNumbers(String body) =>
    parseRegisteredMachines(body).map((m) => m.serial).toList();

abstract class CredentialStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

class _IdentityMapping {
  final String transportType;
  final String deviceId;
  final String serial;

  const _IdentityMapping({
    required this.transportType,
    required this.deviceId,
    required this.serial,
  });

  Map<String, dynamic> toJson() => {
    'transportType': transportType,
    'deviceId': deviceId,
    'serial': serial,
  };

  factory _IdentityMapping.fromJson(Map<String, dynamic> json) =>
      _IdentityMapping(
        transportType: json['transportType'] as String,
        deviceId: json['deviceId'] as String,
        serial: json['serial'] as String,
      );
}

class DecentAccountService {
  static const bool kEnableSerialVerification = true;

  static const String _registeredMachinesKey = 'registered_machines';
  static const String _identityMappingsKey = 'identity_mappings';

  final http.Client _httpClient;
  final CredentialStore _store;
  final String baseUrl;
  final Duration retryInterval;
  final Logger _log = Logger('DecentAccount');

  bool? _authenticated;
  Future<bool>? _validationFuture;
  DateTime? _cooldownUntil;
  int _authGeneration = 0;
  Future<void> _accountWriteLock = Future.value();

  List<RegisteredDecentMachine> _machines = const [];
  List<_IdentityMapping> _mappings = const [];
  bool _cacheLoaded = false;
  bool _hasLinkedAccount = false;
  bool _machinesRefreshed = false;
  Future<void>? _refreshFuture;

  DecentAccountService({
    required http.Client httpClient,
    required CredentialStore credentialStore,
    this.baseUrl = "https://decentespresso.com",
    this.retryInterval = const Duration(seconds: 30),
  }) : _httpClient = httpClient,
       _store = credentialStore;

  Future<void> initialize() async {
    _hasLinkedAccount = await hasLinkedAccount();
    await _loadCachedRegisteredMachines();
    await _loadCachedMappings();
    _cacheLoaded = true;
    unawaited(_ensureMachinesFresh());
  }

  Future<void> get accountReady async {
    final inFlight = _refreshFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    if (_machinesRefreshed || !_cacheLoaded || !_hasLinkedAccount) return;
    await _ensureMachinesFresh();
  }

  Future<void> _ensureMachinesFresh() {
    final inFlight = _refreshFuture;
    if (inFlight != null) return inFlight;
    final future = _backgroundRefresh();
    _refreshFuture = future;
    return future;
  }

  Future<void> _backgroundRefresh() async {
    try {
      if (!await hasLinkedAccount()) return;
      if (!await isLoggedIn()) return;
      await refreshRegisteredMachines();
    } catch (e) {
      _log.info('Background registered-machine refresh unavailable: $e');
    } finally {
      _refreshFuture = null;
    }
  }

  Future<void> _loadCachedRegisteredMachines() async {
    try {
      final raw = await _store.read(key: _registeredMachinesKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (!await _cacheMatchesCurrentAccount(decoded)) return;
      final machinesJson = decoded['machines'] as List? ?? const [];
      _machines = [
        for (final m in machinesJson)
          RegisteredDecentMachine.fromJson(m as Map<String, dynamic>),
      ];
    } catch (e) {
      _log.warning('Failed to load cached registered machines: $e');
    }
  }

  Future<void> _loadCachedMappings() async {
    try {
      final raw = await _store.read(key: _identityMappingsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (!await _cacheMatchesCurrentAccount(decoded)) return;
      _mappings = [
        for (final m in (decoded['mappings'] as List? ?? const []))
          _IdentityMapping.fromJson(m as Map<String, dynamic>),
      ];
    } catch (e) {
      _log.warning('Failed to load cached identity mappings: $e');
    }
  }

  Future<void> _persistRegisteredMachines(
    List<RegisteredDecentMachine> machines, {
    required String account,
  }) async {
    await _store.write(
      key: _registeredMachinesKey,
      value: jsonEncode({
        'account': account,
        'machines': [for (final m in machines) m.toJson()],
      }),
    );
  }

  Future<T> _withAccountWriteLock<T>(Future<T> Function() action) {
    final run = _accountWriteLock.then((_) => action());
    _accountWriteLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<bool> _cacheMatchesCurrentAccount(Map<String, dynamic> decoded) async {
    final storedAccount = decoded['account'] as String?;
    final currentEmail = await _store.read(key: 'email');
    if (storedAccount == null || currentEmail == null) return false;
    return _normalizeEmail(storedAccount) == _normalizeEmail(currentEmail);
  }

  Future<void> _persistMappings(String account) async {
    await _store.write(
      key: _identityMappingsKey,
      value: jsonEncode({
        'account': account,
        'mappings': [for (final m in _mappings) m.toJson()],
      }),
    );
  }

  Future<void> _clearAccountScopedState() {
    return _withAccountWriteLock(() async {
      _machines = const [];
      _mappings = const [];
      _machinesRefreshed = false;
      await _store.delete(key: _registeredMachinesKey);
      await _store.delete(key: _identityMappingsKey);
    });
  }

  static String _normalizeEmail(String email) => email.trim().toLowerCase();

  Future<bool> login(String email, String password) async {
    final response = await _authedGet(
      email,
      password,
      '/support/api/login_test',
    );

    if (response.statusCode == 200 && response.body.trim() != '0') {
      final storedEmail = await _store.read(key: 'email');
      final emailChanged =
          _normalizeEmail(storedEmail ?? '') != _normalizeEmail(email);
      await _store.write(key: 'email', value: email);
      await _store.write(key: 'password', value: response.body.trim());
      _authGeneration++;
      _authenticated = false;
      _hasLinkedAccount = false;
      if (emailChanged) {
        await _clearAccountScopedState();
      }
      _authenticated = true;
      _hasLinkedAccount = true;
      _log.info('login -> accepted');
      try {
        await refreshRegisteredMachines();
      } catch (e) {
        _log.warning('Registered-machine refresh after login failed: $e');
      }
      return true;
    }
    _log.warning('login -> rejected');
    return false;
  }

  Future<void> logout() {
    _authGeneration++;
    _authenticated = false;
    _hasLinkedAccount = false;
    return _withAccountWriteLock(() async {
      _machines = const [];
      _mappings = const [];
      _machinesRefreshed = false;
      await _store.delete(key: _registeredMachinesKey);
      await _store.delete(key: _identityMappingsKey);
      await _store.delete(key: 'email');
      await _store.delete(key: 'password');
    });
  }

  Future<bool> hasLinkedAccount() async =>
      await _store.read(key: 'email') != null &&
      await _store.read(key: 'password') != null;

  bool get hasUsableAccountCache =>
      _cacheLoaded && _hasLinkedAccount && _authenticated != false;

  List<RegisteredDecentMachine> get usableRegisteredMachines =>
      hasUsableAccountCache ? List.unmodifiable(_machines) : const [];

  Future<List<RegisteredDecentMachine>> fetchRegisteredMachines() async {
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    final response = await _authedGet(
      email,
      password,
      '/support/api/sn?onlyespressomachines=1&withskus=1',
    );
    if (response.statusCode != 200) {
      throw Exception(
        'registered machine fetch failed (${response.statusCode}): '
        '${response.body.trim()}',
      );
    }
    final body = response.body.trim();
    if (body == '0') {
      throw StateError('Unexpected response: $body');
    }
    return parseRegisteredMachines(body);
  }

  Future<void> refreshRegisteredMachines() async {
    final generation = _authGeneration;
    final email = await _store.read(key: 'email');
    if (email == null) {
      throw StateError('not logged in');
    }
    final account = _normalizeEmail(email);
    final machines = await fetchRegisteredMachines();
    await _withAccountWriteLock(() async {
      if (generation != _authGeneration) return;
      final currentEmail = await _store.read(key: 'email');
      if (currentEmail == null || _normalizeEmail(currentEmail) != account) {
        return;
      }
      if (generation != _authGeneration) return;
      _machines = machines;
      _cacheLoaded = true;
      _machinesRefreshed = true;
      await _persistRegisteredMachines(machines, account: account);
      await _pruneMappings(machines, account);
    });
  }

  Future<void> saveMapping({
    required String transportType,
    required String deviceId,
    required String serial,
  }) async {
    final generation = _authGeneration;
    final email = await _store.read(key: 'email');
    if (email == null) {
      throw StateError('not logged in');
    }
    final account = _normalizeEmail(email);
    await _withAccountWriteLock(() async {
      if (generation != _authGeneration) return;
      _mappings = [
        ..._mappings.where(
          (m) => !(m.transportType == transportType && m.deviceId == deviceId),
        ),
        _IdentityMapping(
          transportType: transportType,
          deviceId: deviceId,
          serial: serial,
        ),
      ];
      await _persistMappings(account);
    });
  }

  Future<RegisteredDecentMachine?> lookupMapping({
    required String transportType,
    required String deviceId,
  }) async {
    if (!await hasLinkedAccount()) return null;
    final serial = _mappings
        .where(
          (m) => m.transportType == transportType && m.deviceId == deviceId,
        )
        .map((m) => m.serial)
        .firstOrNull;
    if (serial == null) return null;
    return _machines.where((m) => m.serial == serial).firstOrNull;
  }

  Future<void> _pruneMappings(
    List<RegisteredDecentMachine> machines,
    String account,
  ) async {
    final serials = machines.map((m) => m.serial).toSet();
    final pruned = _mappings.where((m) => serials.contains(m.serial)).toList();
    if (pruned.length == _mappings.length) return;
    _mappings = pruned;
    await _persistMappings(account);
  }

  Future<bool> isLoggedIn() async {
    if (!await hasLinkedAccount()) return false;
    final cached = _authenticated;
    if (cached != null) return cached;
    final pending = _validationFuture;
    if (pending != null) return pending;
    final cooldownUntil = _cooldownUntil;
    if (cooldownUntil != null) {
      if (clock.now().isBefore(cooldownUntil)) return false;
      _cooldownUntil = null;
    }
    final future = verifyStoredCredentials();
    _validationFuture = future;
    future.whenComplete(() {
      _validationFuture = null;
      if (_authenticated == null) {
        _cooldownUntil = clock.now().add(retryInterval);
      }
    });
    return future;
  }

  Future<bool> verifyStoredCredentials() async {
    final generation = _authGeneration;
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      _log.info('validation -> no stored credentials (account not linked)');
      _setAuthenticated(generation, false);
      return false;
    }
    final http.Response response;
    try {
      response = await _authedGet(email, password, '/support/api/login_test');
    } catch (_) {
      _log.info('validation -> indeterminate');
      return _authenticated ?? false;
    }
    final valid = response.statusCode == 200 && response.body.trim() != '0';
    final rejected =
        response.statusCode == 401 ||
        (response.statusCode == 200 && response.body.trim() == '0');
    if (!valid && !rejected) {
      _log.info('validation -> indeterminate');
      return _authenticated ?? false;
    }
    if (valid) {
      _log.info('validation -> accepted');
      _setAuthenticated(generation, valid);
      if (!_machinesRefreshed) {
        unawaited(_ensureMachinesFresh());
      }
      return _authenticated ?? false;
    }
    _log.info('validation -> rejected');
    _setAuthenticated(generation, false);
    return _authenticated ?? false;
  }

  void _setAuthenticated(int generation, bool value) {
    if (generation == _authGeneration) _authenticated = value;
  }

  void reportAuthenticationFailure() {
    _authGeneration++;
    _authenticated = false;
  }

  Future<bool> isAuthKnownInvalid() async => _authenticated == false;

  Future<String?> getEmail() async => _store.read(key: 'email');

  Future<List<String>> fetchSerialNumbers() async =>
      (await fetchRegisteredMachines()).map((m) => m.serial).toList();

  Future<bool> verifyMachineSerial(String serial) async {
    final list = await fetchSerialNumbers();
    return list.contains(serial);
  }

  Future<void> emailSerialMismatch(String serial) async {
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    final subject = Uri.encodeComponent(
      'My machine serial number #$serial is not associated with my login',
    );
    final body = Uri.encodeComponent(
      'I linked my de1app to my Decent account, and found that this '
      'account does not list the machine #$serial I am connected to.',
    );
    final response = await _authedGet(
      email,
      password,
      '/support/api/email?subject=$subject&body=$body',
    );
    final responseBody = response.body.trim();
    if (response.statusCode != 200 || responseBody == '0') {
      throw Exception(
        'email serial mismatch failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  Future<http.Response> _authedGet(
    String email,
    String password,
    String path,
  ) async {
    final basic = base64Encode(
      utf8.encode("${email.trim()}:${password.trim()}"),
    );
    return _httpClient.get(
      Uri.parse('$baseUrl$path'),
      headers: {'authorization': "Basic $basic"},
    );
  }
}
