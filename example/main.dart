// ignore_for_file: avoid_print

// Migrating a Flutter app from Hive and SharedPreferences to ReaxDB, once,
// the first time the new version starts.
//
// Your app keeps its own Hive setup (Hive.initFlutter, registerAdapter) for
// the migration, and can drop Hive and this package in a later version.
import 'package:hive_ce/hive_ce.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:reaxdb_migrate/reaxdb_migrate.dart';

Future<ReaxDB> openMigrated(String path) async {
  final ReaxDB db = await ReaxDB.open(path: path);
  if (await db.get<bool>('migrated') == true) return db;

  final MigrateReport fromHive = await ReaxMigrate.fromHive(
    <String>['users', 'settings'],
    into: db,
    deleteHiveBoxes: true,
    onProgress: (MigrationProgress p) {
      print('${p.source}: ${(p.fraction * 100).round()}%');
    },
  );
  final MigrateReport fromPrefs = await ReaxMigrate.fromSharedPreferences(
    into: db,
    removeAfter: true,
  );
  print(fromHive);
  print(fromPrefs);

  // Only marked as done when everything was copied and verified, so an
  // interrupted migration simply runs again on the next start.
  if (fromHive.isComplete && fromPrefs.isComplete) {
    await db.put('migrated', true);
  }
  return db;
}

Future<void> main() async {
  Hive.init('hive_data');
  final ReaxDB db = await openMigrated('reaxdb_data');
  print(await db.query('users').count());
  await db.close();
}
