/// What a migration did, and how far it is while it runs.
library;

/// One entry that could not be migrated, and why.
final class MigrationFailure {
  /// Creates a failure.
  const MigrationFailure(this.source, this.key, this.error);

  /// Where the entry came from, such as `hive:users`.
  final String source;

  /// The entry's key in the source.
  final Object? key;

  /// What went wrong: the value could not be read or converted, or ReaxDB
  /// could not store it.
  final Object error;

  @override
  String toString() => 'MigrationFailure($source, $key: $error)';
}

/// The result of comparing the source with ReaxDB after copying.
final class VerificationResult {
  /// Creates a result.
  const VerificationResult({
    required this.checked,
    required this.mismatched,
    required this.mismatchedKeys,
  });

  /// Entries compared.
  final int checked;

  /// Entries whose value in ReaxDB differs from the source.
  final int mismatched;

  /// The first [SourceReport.maxRecordedKeys] keys that differ.
  final List<Object?> mismatchedKeys;

  /// Whether every compared entry matched.
  bool get passed => mismatched == 0;

  @override
  String toString() =>
      'VerificationResult(checked: $checked, mismatched: $mismatched)';
}

/// What happened to one source: a Hive box or a SharedPreferences store.
final class SourceReport {
  /// Creates a report.
  const SourceReport({
    required this.source,
    required this.total,
    required this.imported,
    required this.skipped,
    required this.failed,
    required this.failures,
    required this.verification,
    required this.deleted,
    required this.elapsed,
  });

  /// How many keys a report keeps in its lists, so a huge migration with
  /// many problems does not hold them all in memory.
  static const int maxRecordedKeys = 1000;

  /// The source, such as `hive:users` or `shared_preferences`.
  final String source;

  /// Entries in the source.
  final int total;

  /// Entries written to ReaxDB.
  final int imported;

  /// Entries left out: their key already existed (`skipExisting`), or the
  /// `convert` callback returned [ReaxMigrateSkip].
  final int skipped;

  /// Entries that could not be migrated.
  final int failed;

  /// The first [maxRecordedKeys] failures. [failed] counts all of them.
  final List<MigrationFailure> failures;

  /// The comparison after copying, or null when `verify` was false.
  final VerificationResult? verification;

  /// Whether the source was deleted after a clean migration.
  final bool deleted;

  /// Time spent on this source.
  final Duration elapsed;

  /// Whether every entry was migrated (or skipped) and, when checked,
  /// matches.
  bool get isComplete => failed == 0 && (verification?.passed ?? true);

  @override
  String toString() {
    final StringBuffer out = StringBuffer(
      '$source: $imported of $total migrated',
    );
    if (skipped > 0) out.write(', $skipped skipped');
    if (failed > 0) out.write(', $failed failed');
    final VerificationResult? v = verification;
    if (v != null) {
      out.write(
        v.passed ? ', verified' : ', ${v.mismatched} differ after copying',
      );
    }
    if (deleted) out.write(', source deleted');
    out.write(' (${elapsed.inMilliseconds} ms)');
    return out.toString();
  }
}

/// The result of a migration of one or more sources.
final class MigrateReport {
  /// Creates a report.
  const MigrateReport(this.sources, this.elapsed);

  /// One report per source, in the order they were migrated.
  final List<SourceReport> sources;

  /// Time spent in total.
  final Duration elapsed;

  /// Entries written to ReaxDB, over all sources.
  int get imported =>
      sources.fold<int>(0, (int sum, SourceReport s) => sum + s.imported);

  /// Entries left out, over all sources.
  int get skipped =>
      sources.fold<int>(0, (int sum, SourceReport s) => sum + s.skipped);

  /// Entries that could not be migrated, over all sources.
  int get failed =>
      sources.fold<int>(0, (int sum, SourceReport s) => sum + s.failed);

  /// Whether every source migrated completely and, when checked, matches.
  bool get isComplete => sources.every((SourceReport s) => s.isComplete);

  @override
  String toString() => <String>[
    'Migration ${isComplete ? 'complete' : 'incomplete'}: $imported migrated, '
        '$skipped skipped, $failed failed in ${elapsed.inMilliseconds} ms',
    for (final SourceReport s in sources) '  $s',
  ].join('\n');
}

/// Progress of a running migration.
final class MigrationProgress {
  /// Creates a progress update.
  const MigrationProgress({
    required this.source,
    required this.sourceIndex,
    required this.sourceCount,
    required this.processed,
    required this.total,
  });

  /// The source being migrated.
  final String source;

  /// Index of [source] among all sources, from 0.
  final int sourceIndex;

  /// Number of sources in this migration.
  final int sourceCount;

  /// Entries of [source] handled so far.
  final int processed;

  /// Entries in [source].
  final int total;

  /// Progress of [source], from 0 to 1.
  double get fraction => total == 0 ? 1 : processed / total;

  @override
  String toString() =>
      'MigrationProgress($source ${sourceIndex + 1}/$sourceCount: '
      '$processed/$total)';
}

/// Return [ReaxMigrate.skip] from a `convert` callback to leave an entry out.
final class ReaxMigrateSkip {
  const ReaxMigrateSkip._();

  /// The single instance, exposed as `ReaxMigrate.skip`.
  static const ReaxMigrateSkip instance = ReaxMigrateSkip._();
}
