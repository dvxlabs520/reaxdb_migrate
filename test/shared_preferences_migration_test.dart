import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:reaxdb_migrate/reaxdb_migrate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ReaxDB db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reaxdb_migrate_prefs_');
    db = await ReaxDB.open(path: '${root.path}/reax', syncMode: SyncMode.none);
  });

  tearDown(() async {
    await ReaxDB.closeAll();
    await root.delete(recursive: true);
  });

  group('SharedPreferences', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'theme': 'dark',
        'launches': 12,
        'volume': 0.5,
        'onboarded': true,
        'recent': <String>['a', 'b'],
      });
    });

    test('copies every value under prefs:', () async {
      final MigrateReport report = await ReaxMigrate.fromSharedPreferences(
        into: db,
      );
      expect(report.isComplete, isTrue, reason: '$report');
      expect(report.imported, 5);
      expect(await db.get<String>('prefs:theme'), 'dark');
      expect(await db.get<int>('prefs:launches'), 12);
      expect(await db.get<double>('prefs:volume'), 0.5);
      expect(await db.get<bool>('prefs:onboarded'), isTrue);
      expect(await db.get<List<dynamic>>('prefs:recent'), <String>['a', 'b']);
    });

    test('only the keys asked for, and removed afterwards', () async {
      final MigrateReport report = await ReaxMigrate.fromSharedPreferences(
        into: db,
        keys: <String>{'theme', 'launches'},
        collection: 'settings',
        removeAfter: true,
      );
      expect(report.imported, 2);
      expect(report.sources.single.deleted, isTrue);
      expect(await db.get<String>('settings:theme'), 'dark');

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('theme'), isFalse);
      expect(prefs.containsKey('launches'), isFalse);
      expect(prefs.getStringList('recent'), <String>['a', 'b']);
    });

    test('keys can be kept as they are', () async {
      await ReaxMigrate.fromSharedPreferences(into: db, collection: null);
      expect(await db.get<String>('theme'), 'dark');
    });
  });

  group('SharedPreferencesAsync', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(<String, Object>{
            'token_expiry': 1700000000,
            'locale': 'es',
          });
    });

    test('copies values saved with the async API', () async {
      final MigrateReport report = await ReaxMigrate.fromSharedPreferencesAsync(
        into: db,
        removeAfter: true,
      );
      expect(report.isComplete, isTrue, reason: '$report');
      expect(await db.get<String>('prefs:locale'), 'es');
      expect(await db.get<int>('prefs:token_expiry'), 1700000000);
      expect(
        await SharedPreferencesAsync().getAll(),
        isEmpty,
        reason: 'removed after a clean migration',
      );
    });
  });
}
