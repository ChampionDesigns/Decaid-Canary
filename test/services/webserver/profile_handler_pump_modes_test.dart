import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

/// The profile STORAGE routes are machine-independent — they must accept and
/// round-trip pump:"power"/"lever" profiles regardless of any connected
/// machine's capabilities (the refusal gate lives on the machine-push path
/// only).
class _StubStorage implements ProfileStorageService {
  final Map<String, ProfileRecord> _records = {};

  @override
  Future<void> initialize() async {}
  @override
  Future<void> store(ProfileRecord record) async =>
      _records[record.id] = record;
  @override
  Future<ProfileRecord?> get(String id) async => _records[id];
  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async =>
      _records.values.toList();
  @override
  Future<void> update(ProfileRecord record) async =>
      _records[record.id] = record;
  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {
    _records[replacement.id] = replacement;
    _records.remove(oldId);
  }

  @override
  Future<void> delete(String id) async => _records.remove(id);
  @override
  Future<bool> exists(String id) async => _records.containsKey(id);
  @override
  Future<List<String>> getAllIds() async => _records.keys.toList();
  @override
  Future<List<ProfileRecord>> getByParentId(String parentId) async => const [];
  @override
  Future<void> storeAll(List<ProfileRecord> records) async {
    for (final r in records) {
      _records[r.id] = r;
    }
  }

  @override
  Future<void> clear() async => _records.clear();
  @override
  Future<int> count({Visibility? visibility}) async => _records.length;
}

void main() {
  late Handler handler;

  Future<Response> postProfile(Map<String, dynamic> body) async {
    return await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/profiles'),
        body: jsonEncode(body),
      ),
    );
  }

  Future<Response> putProfile(String id, Map<String, dynamic> body) async {
    return await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/profiles/$id'),
        body: jsonEncode(body),
      ),
    );
  }

  setUp(() {
    final controller = ProfileController(storage: _StubStorage());
    final profileHandler = ProfileHandler(controller: controller);
    final app = Router().plus;
    profileHandler.addRoutes(app);
    handler = app.call;
  });

  Map<String, dynamic> leverProfile() => {
    'version': '2',
    'title': 'Lever demo',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'lever',
        'pump': 'lever',
        'transition': 'smooth',
        'volume': 100,
        'seconds': 40,
        'temperature': 92,
        'sensor': 'coffee',
        'pressure': 9.0,
        'leverSpring': 0.9,
        'leverGive': 1.5,
      },
    ],
    'tank_temperature': 90.0,
    'target_weight': 36.0,
    'target_volume_count_start': 0,
  };

  Map<String, dynamic> powerProfile() => {
    'version': '2',
    'title': 'Power demo',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'power',
        'pump': 'power',
        'transition': 'smooth',
        'volume': 100,
        'seconds': 25,
        'temperature': 93,
        'sensor': 'coffee',
        'power': 2.0,
        'limiter': {'value': 9.0, 'range': 0.6},
      },
    ],
    'tank_temperature': 90.0,
    'target_weight': 36.0,
    'target_volume_count_start': 0,
  };

  group('POST /api/v1/profiles (storage) accepts novel pump-mode profiles', () {
    test('a lever profile stores (201) and round-trips', () async {
      final response = await postProfile({'profile': leverProfile()});

      expect(response.statusCode, 201);
      final record =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final step =
          (record['profile']['steps'] as List).first as Map<String, dynamic>;
      expect(step['pump'], 'lever');
      expect(step['pressure'], 9.0);
      expect(step['leverSpring'], 0.9);
      expect(step['leverGive'], 1.5);
    });

    test('a power profile stores (201) and round-trips its limiter', () async {
      final response = await postProfile({'profile': powerProfile()});

      expect(response.statusCode, 201);
      final record =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final step =
          (record['profile']['steps'] as List).first as Map<String, dynamic>;
      expect(step['pump'], 'power');
      expect(step['power'], 2.0);
      expect(step['limiter']['value'], 9.0);
    });

    test(
      'a power profile WITHOUT a limiter is a 400 (schema violation)',
      () async {
        final body = powerProfile();
        (body['steps'] as List).first.remove('limiter');

        final response = await postProfile({'profile': body});

        expect(response.statusCode, 400);
      },
    );
  });

  group('a power step limiter on POST and PUT', () {
    const rangeRefusal = {
      'error': 'Invalid request',
      'message': 'FormatException: limiter "range" must be a number',
    };
    const valueRefusal = {
      'error': 'Invalid request',
      'message': 'FormatException: limiter "value" must be a number',
    };

    Map<String, dynamic> powerProfileWithLimiter(dynamic limiter) {
      final body = powerProfile();
      (body['steps'] as List).first['limiter'] = limiter;
      return body;
    }

    Future<String> seedRecord() async {
      final response = await postProfile({'profile': powerProfile()});
      final created =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      return created['id'] as String;
    }

    Future<Map<String, dynamic>> decode(Response response) async =>
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    final refusedForms = <String, (Map<String, dynamic>, Map<String, String>)>{
      '(a) {value: 6}': (const {'value': 6}, rangeRefusal),
      '(c) {value: 6, range: null}': (
        const {'value': 6, 'range': null},
        rangeRefusal,
      ),
      '(d) {range: 1}': (const {'range': 1}, valueRefusal),
      '(e) {value: null, range: 1}': (
        const {'value': null, 'range': 1},
        valueRefusal,
      ),
      '(f) {value: 6, range: "x"}': (
        const {'value': 6, 'range': 'x'},
        rangeRefusal,
      ),
    };

    for (final MapEntry(key: form, value: (limiter, refusal))
        in refusedForms.entries) {
      test(
        'form $form: POST and PUT both answer 400 with the same text',
        () async {
          final id = await seedRecord();
          final body = {'profile': powerProfileWithLimiter(limiter)};

          final post = await postProfile(body);
          final put = await putProfile(id, body);

          expect(post.statusCode, 400);
          expect(put.statusCode, 400);
          expect(await decode(post), refusal);
          expect(await decode(put), refusal);
        },
      );
    }

    test('form (b) {value: 6, range: 0}: POST and PUT store range 0', () async {
      final id = await seedRecord();
      final body = {
        'profile': powerProfileWithLimiter({'value': 6, 'range': 0}),
      };

      final post = await postProfile(body);
      final put = await putProfile(id, body);

      expect(post.statusCode, 201);
      expect(put.statusCode, 200);
      for (final response in [post, put]) {
        final record = await decode(response);
        final step =
            (record['profile']['steps'] as List).single as Map<String, dynamic>;
        expect(step['pump'], 'power');
        expect(step['limiter'], {'value': 6.0, 'range': 0.0});
      }
    });

    final nonFiniteForms = <(Map<String, dynamic>, String)>[
      (const {'value': 'NaN', 'range': 1}, 'value'),
      (const {'value': 'Infinity', 'range': 1}, 'value'),
      (const {'value': 6, 'range': 'NaN'}, 'range'),
      (const {'value': 6, 'range': '-Infinity'}, 'range'),
    ];

    for (final (limiter, field) in nonFiniteForms) {
      test('$limiter: POST and PUT both answer 400 naming "$field"', () async {
        final refusal = {
          'error': 'Invalid request',
          'message':
              'FormatException: limiter "$field" must be a finite number',
        };
        final id = await seedRecord();
        final body = {'profile': powerProfileWithLimiter(limiter)};

        final post = await postProfile(body);
        final put = await putProfile(id, body);

        expect(post.statusCode, 400);
        expect(put.statusCode, 400);
        expect(await decode(post), refusal);
        expect(await decode(put), refusal);
      });
    }
  });
}
