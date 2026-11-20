/// Moves data from Hive or SharedPreferences into ReaxDB.
///
/// Add this package for the migration and remove it afterwards:
///
/// ```dart
/// final report = await ReaxMigrate.fromHive(['users', 'settings'], into: db);
/// print(report);
/// ```
library;

export 'src/reax_migrate.dart' show ReaxMigrate;
export 'src/report.dart'
    show
        MigrationFailure,
        MigrationProgress,
        MigrateReport,
        ReaxMigrateSkip,
        SourceReport,
        VerificationResult;
export 'src/source_migration.dart' show MigrationConverter;
export 'src/value_conversion.dart' show toStorableValue;
