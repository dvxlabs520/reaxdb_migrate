/// The steps every source goes through: copy, verify, report.
library;

import 'package:reaxdb_dart/reaxdb_dart.dart';

import 'report.dart';
import 'value_conversion.dart';

/// Converts a value from a source before it is stored. Return
/// `ReaxMigrate.skip` to leave the entry out.
typedef MigrationConverter =
    Object? Function(String source, Object? key, Object? value);

/// One source to migrate, described by its keys and how to read them.
final class SourceDescription {
  /// Creates a description.
  SourceDescription({
    required this.name,
    required this.keys,
    required this.read,
    required this.targetKey,
  });

  /// Name used in reports, such as `hive:users`.
  final String name;

  /// Every key of the source.
  final List<Object?> keys;

  /// Reads the value of a key.
  final Future<Object?> Function(Object? key) read;

  /// The ReaxDB key a source key is stored under.
  final String Function(Object? key) targetKey;
}

/// Copies [source] into [db], optionally verifies it, and reports.
///
/// Values are read and written one batch at a time through
/// `ReaxDB.importEntries`, so memory stays at about one batch whatever the
/// size of the source (plus the keys of entries left out, when there are
/// any). [deleteSource] runs only when every entry was copied and, if
/// [verify] is set, matches.
Future<SourceReport> migrateSource(
  SourceDescription source, {
  required ReaxDB db,
  required int sourceIndex,
  required int sourceCount,
  required MigrationConverter? convert,
  required int batchSize,
  required bool skipExisting,
  required bool verify,
  required Future<void> Function()? deleteSource,
  required void Function(MigrationProgress progress)? onProgress,
}) async {
  final Stopwatch clock = Stopwatch()..start();
  final int total = source.keys.length;
  int readFailed = 0;
  int skipped = 0;
  final List<MigrationFailure> failures = <MigrationFailure>[];
  // Target keys not written in this run, which verification must not
  // compare: they failed, or already held the app's own data.
  final Set<String> notWritten = <String>{};

  void record(Object? key, Object error) {
    if (failures.length < SourceReport.maxRecordedKeys) {
      failures.add(MigrationFailure(source.name, key, error));
    }
  }

  /// The value to store for [key], or [ReaxMigrateSkip.instance].
  Future<Object?> storable(Object? key) async {
    Object? value = await source.read(key);
    final MigrationConverter? converter = convert;
    if (converter != null) value = converter(source.name, key, value);
    if (identical(value, ReaxMigrateSkip.instance)) return value;
    return toStorableValue(value);
  }

  Stream<MapEntry<String, Object?>> entries() async* {
    for (final Object? key in source.keys) {
      final String target;
      final Object? value;
      try {
        target = source.targetKey(key);
        value = await storable(key);
      } catch (error) {
        readFailed++;
        record(key, error);
        continue;
      }
      if (identical(value, ReaxMigrateSkip.instance)) {
        skipped++;
        continue;
      }
      if (skipExisting && await db.exists(target)) {
        skipped++;
        notWritten.add(target);
        continue;
      }
      yield MapEntry<String, Object?>(target, value);
    }
  }

  void progress(ImportReport sofar) {
    onProgress?.call(
      MigrationProgress(
        source: source.name,
        sourceIndex: sourceIndex,
        sourceCount: sourceCount,
        processed: sofar.processed + readFailed + skipped,
        total: total,
      ),
    );
  }

  final ImportReport imported = await db.importEntries(
    entries(),
    batchSize: batchSize,
    onProgress: progress,
  );

  // ImportReport names failures by target key; report them by source key.
  if (imported.failures.isNotEmpty) {
    final Set<String> failedTargets = <String>{
      for (final ImportFailure f in imported.failures) f.key,
    };
    notWritten.addAll(failedTargets);
    final Map<String, Object?> sourceKeyOf = <String, Object?>{};
    for (final Object? key in source.keys) {
      try {
        final String target = source.targetKey(key);
        if (failedTargets.contains(target)) sourceKeyOf[target] = key;
      } catch (_) {
        // Already reported as a read failure.
      }
    }
    for (final ImportFailure f in imported.failures) {
      record(sourceKeyOf[f.key] ?? f.key, f.error);
    }
  }
  final int failed = readFailed + imported.failed;

  final VerificationResult? verification = verify
      ? await _verify(
          source,
          db: db,
          storable: storable,
          notWritten: notWritten,
        )
      : null;

  bool deleted = false;
  final Future<void> Function()? delete = deleteSource;
  if (delete != null &&
      failed == 0 &&
      skipped == 0 &&
      (verification?.passed ?? true)) {
    await delete();
    deleted = true;
  }

  return SourceReport(
    source: source.name,
    total: total,
    imported: imported.imported,
    skipped: skipped,
    failed: failed,
    failures: List<MigrationFailure>.unmodifiable(failures),
    verification: verification,
    deleted: deleted,
    elapsed: clock.elapsed,
  );
}

/// Reads every entry again and compares it with what ReaxDB holds.
Future<VerificationResult> _verify(
  SourceDescription source, {
  required ReaxDB db,
  required Future<Object?> Function(Object? key) storable,
  required Set<String> notWritten,
}) async {
  int checked = 0;
  int mismatched = 0;
  final List<Object?> mismatchedKeys = <Object?>[];
  for (final Object? key in source.keys) {
    final String target;
    final Object? expected;
    try {
      target = source.targetKey(key);
      expected = await storable(key);
    } catch (_) {
      continue; // Reported as a failure while copying.
    }
    if (identical(expected, ReaxMigrateSkip.instance)) continue;
    if (notWritten.contains(target)) continue;
    final Object? stored = await db.get<Object>(target);
    checked++;
    if (stored == null && expected != null || !valuesEqual(stored, expected)) {
      mismatched++;
      if (mismatchedKeys.length < SourceReport.maxRecordedKeys) {
        mismatchedKeys.add(key);
      }
    }
  }
  return VerificationResult(
    checked: checked,
    mismatched: mismatched,
    mismatchedKeys: List<Object?>.unmodifiable(mismatchedKeys),
  );
}
