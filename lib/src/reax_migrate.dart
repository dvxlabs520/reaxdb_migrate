import 'dart:io';

import 'package:hive_ce/hive_ce.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'report.dart';
import 'source_migration.dart';

/// Moves data from Hive or SharedPreferences into a ReaxDB database.
///
/// Every migration copies in atomic batches with bounded memory, reports
/// progress, can verify the copy against the source, and returns a
/// [MigrateReport]. Running a migration again is safe: entries are
/// overwritten, not duplicated.
abstract final class ReaxMigrate {
  /// Return this from a `convert` callback to leave an entry out.
  static const ReaxMigrateSkip skip = ReaxMigrateSkip.instance;

  /// Copies the Hive boxes named [boxes] into [into], one after the other.
  ///
  /// By default each box becomes a collection with the box's name: the
  /// entry `'ada'` of box `users` is stored under `users:ada`, so ReaxDB
  /// queries work on it. Integer keys become strings (`users:42`).
  /// [collection] maps a box name to another collection name, or to null
  /// to store keys as they are.
  ///
  /// A box whose file is at most [inMemoryLimitBytes] (16 MB by default) is
  /// read whole, which is fast; a larger one is read as a lazy box, one
  /// value at a time, so a box of any size migrates without loading its
  /// values into memory. Decoded values take several times their size on
  /// disk, so raise the limit with care on phones. A box the app has already opened (as a box or a lazy
  /// box) is read as it is and left open. Otherwise it is opened from
  /// [directory] (or from where Hive was initialized) and closed afterwards.
  /// Encrypted boxes need their [cipher], or one per box in [ciphers].
  ///
  /// Values are converted as described in `toStorableValue`: `DateTime`
  /// becomes an ISO 8601 string, `Set` a list, and so on. Objects stored
  /// with a `TypeAdapter` need that adapter registered (as the app already
  /// does) and either a `toJson()` method or a [convert] callback that
  /// returns a map, a list or a primitive for them. [convert] runs first
  /// for every value; return [skip] to leave an entry out.
  ///
  /// With [skipExisting], keys that already hold a value in ReaxDB are left
  /// alone. With [verify] (the default) every copied entry is read back and
  /// compared. With [deleteHiveBoxes], a box is deleted from disk once it
  /// migrated completely: no failures, nothing skipped, and verified when
  /// [verify] is set.
  ///
  /// An entry that cannot be read, converted or stored is reported in the
  /// result and does not stop the migration. An error writing to ReaxDB,
  /// such as a full disk, stops it and is thrown; run it again once fixed.
  static Future<MigrateReport> fromHive(
    List<String> boxes, {
    required ReaxDB into,
    String? directory,
    HiveCipher? cipher,
    Map<String, HiveCipher>? ciphers,
    String? Function(String box)? collection,
    MigrationConverter? convert,
    int batchSize = 500,
    bool skipExisting = false,
    bool verify = true,
    bool deleteHiveBoxes = false,
    int inMemoryLimitBytes = 16 * 1024 * 1024,
    void Function(MigrationProgress progress)? onProgress,
  }) async {
    final Stopwatch clock = Stopwatch()..start();
    final List<SourceReport> reports = <SourceReport>[];
    for (int i = 0; i < boxes.length; i++) {
      final String box = boxes[i];
      final String? target = collection == null ? box : collection(box);
      _checkCollection(target);
      final _HiveBox opened = await _HiveBox.open(
        box,
        cipher: ciphers?[box] ?? cipher,
        directory: directory,
        inMemoryLimitBytes: inMemoryLimitBytes,
      );
      try {
        reports.add(
          await migrateSource(
            SourceDescription(
              name: 'hive:$box',
              keys: opened.keys,
              read: opened.read,
              targetKey: (Object? key) =>
                  target == null ? '$key' : '$target:$key',
            ),
            db: into,
            sourceIndex: i,
            sourceCount: boxes.length,
            convert: convert,
            batchSize: batchSize,
            skipExisting: skipExisting,
            verify: verify,
            deleteSource: deleteHiveBoxes
                ? () => Hive.deleteBoxFromDisk(box, path: directory)
                : null,
            onProgress: onProgress,
          ),
        );
      } finally {
        await opened.closeIfOpenedHere();
      }
    }
    return MigrateReport(
      List<SourceReport>.unmodifiable(reports),
      clock.elapsed,
    );
  }

  /// Copies values saved with the classic `SharedPreferences` API into
  /// [into].
  ///
  /// Keys are stored under [collection] (`prefs:theme` by default), or as
  /// they are when [collection] is null. [keys] limits the migration to
  /// those keys. With [removeAfter], migrated keys are removed from
  /// SharedPreferences once the migration is complete and verified.
  ///
  /// Uses `SharedPreferences.getInstance()` unless [preferences] is given.
  /// Data saved with `SharedPreferencesAsync` or
  /// `SharedPreferencesWithCache` lives in a different store on Android:
  /// use [fromSharedPreferencesAsync] for it.
  static Future<MigrateReport> fromSharedPreferences({
    required ReaxDB into,
    SharedPreferences? preferences,
    Set<String>? keys,
    String? collection = 'prefs',
    MigrationConverter? convert,
    bool skipExisting = false,
    bool verify = true,
    bool removeAfter = false,
    void Function(MigrationProgress progress)? onProgress,
  }) async {
    _checkCollection(collection);
    final Stopwatch clock = Stopwatch()..start();
    final SharedPreferences prefs =
        preferences ?? await SharedPreferences.getInstance();
    await prefs.reload();
    final List<String> selected = <String>[
      for (final String key in prefs.getKeys())
        if (keys == null || keys.contains(key)) key,
    ]..sort();
    final SourceReport report = await migrateSource(
      SourceDescription(
        name: 'shared_preferences',
        keys: selected,
        read: (Object? key) async => prefs.get(key! as String),
        targetKey: (Object? key) =>
            collection == null ? '$key' : '$collection:$key',
      ),
      db: into,
      sourceIndex: 0,
      sourceCount: 1,
      convert: convert,
      batchSize: 500,
      skipExisting: skipExisting,
      verify: verify,
      deleteSource: removeAfter
          ? () async {
              for (final String key in selected) {
                await prefs.remove(key);
              }
            }
          : null,
      onProgress: onProgress,
    );
    return MigrateReport(<SourceReport>[report], clock.elapsed);
  }

  /// Copies values saved with `SharedPreferencesAsync` or
  /// `SharedPreferencesWithCache` into [into]. Otherwise the same as
  /// [fromSharedPreferences].
  static Future<MigrateReport> fromSharedPreferencesAsync({
    required ReaxDB into,
    SharedPreferencesAsync? preferences,
    Set<String>? keys,
    String? collection = 'prefs',
    MigrationConverter? convert,
    bool skipExisting = false,
    bool verify = true,
    bool removeAfter = false,
    void Function(MigrationProgress progress)? onProgress,
  }) async {
    _checkCollection(collection);
    final Stopwatch clock = Stopwatch()..start();
    final SharedPreferencesAsync prefs =
        preferences ?? SharedPreferencesAsync();
    final Map<String, Object?> values = await prefs.getAll(allowList: keys);
    final List<String> selected = values.keys.toList()..sort();
    final SourceReport report = await migrateSource(
      SourceDescription(
        name: 'shared_preferences_async',
        keys: selected,
        read: (Object? key) async => values[key],
        targetKey: (Object? key) =>
            collection == null ? '$key' : '$collection:$key',
      ),
      db: into,
      sourceIndex: 0,
      sourceCount: 1,
      convert: convert,
      batchSize: 500,
      skipExisting: skipExisting,
      verify: verify,
      deleteSource: removeAfter
          ? () async {
              for (final String key in selected) {
                await prefs.remove(key);
              }
            }
          : null,
      onProgress: onProgress,
    );
    return MigrateReport(<SourceReport>[report], clock.elapsed);
  }

  static void _checkCollection(String? collection) {
    if (collection == null) return;
    if (collection.isEmpty || collection.contains(':')) {
      throw ArgumentError.value(
        collection,
        'collection',
        'must be non-empty and must not contain ":"',
      );
    }
  }
}

/// A Hive box opened for reading, lazily when this code opened it.
final class _HiveBox {
  _HiveBox(this.keys, this.read, this._close);

  final List<Object?> keys;
  final Future<Object?> Function(Object? key) read;
  final Future<void> Function()? _close;

  static Future<_HiveBox> open(
    String name, {
    required HiveCipher? cipher,
    required String? directory,
    required int inMemoryLimitBytes,
  }) async {
    if (Hive.isBoxOpen(name)) {
      // The app's own box: read it as it is, and leave it open.
      try {
        final LazyBox<dynamic> lazy = Hive.lazyBox<dynamic>(name);
        return _HiveBox(lazy.keys.toList(), (Object? k) => lazy.get(k), null);
      } on HiveError {
        final Box<dynamic> box = Hive.box<dynamic>(name);
        return _HiveBox(
          box.keys.toList(),
          (Object? k) async => box.get(k),
          null,
        );
      }
    }
    // Opening lazily loads only the keys, and tells where the file is.
    final LazyBox<dynamic> lazy = await Hive.openLazyBox<dynamic>(
      name,
      encryptionCipher: cipher,
      path: directory,
    );
    final String? file = lazy.path;
    final int size = file == null ? -1 : await File(file).length();
    if (size >= 0 && size <= inMemoryLimitBytes) {
      // Small enough to read whole, which is much faster than one disk
      // read per value.
      await lazy.close();
      final Box<dynamic> box = await Hive.openBox<dynamic>(
        name,
        encryptionCipher: cipher,
        path: directory,
      );
      return _HiveBox(
        box.keys.toList(),
        (Object? k) async => box.get(k),
        box.close,
      );
    }
    return _HiveBox(lazy.keys.toList(), (Object? k) => lazy.get(k), lazy.close);
  }

  /// Closes the box unless the app had opened it, or it was deleted.
  Future<void> closeIfOpenedHere() async {
    final Future<void> Function()? close = _close;
    if (close == null) return;
    try {
      await close();
    } on HiveError {
      // Already closed by deleteBoxFromDisk.
    }
  }
}
