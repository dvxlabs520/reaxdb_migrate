# reaxdb_migrate

Move your data from Hive or SharedPreferences into
[ReaxDB](https://pub.dev/packages/reaxdb_dart), in one call.

- **Any size.** Small boxes are read whole, large ones one value at a time,
  so a box with a million entries migrates without loading it into memory.
- **Safe to run again.** Data is written in atomic batches. If the app is
  killed halfway, run the migration again: nothing is duplicated.
- **Checked.** Every copied entry is read back and compared, and you get a
  report of what was migrated, skipped or failed.
- **Temporary.** Add this package for the migration, remove it afterwards.

## Install

```bash
flutter pub add reaxdb_migrate
```

## From Hive

```dart
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';
import 'package:reaxdb_migrate/reaxdb_migrate.dart';

await Hive.initFlutter(); // as your app already does
Hive.registerAdapter(UserAdapter()); // your adapters, if any

final db = await ReaxFlutter.open('app');

final report = await ReaxMigrate.fromHive(['users', 'settings'], into: db);
print(report);
// Migration complete: 12403 migrated, 0 skipped, 0 failed in 1840 ms
//   hive:users: 12391 of 12391 migrated, verified (1790 ms)
//   hive:settings: 12 of 12 migrated, verified (50 ms)
```

Each box becomes a collection with its name: entry `ada` of box `users` is
stored under `users:ada`, so ReaxDB queries work on it right away:

```dart
final adults = await db.query('users').whereGreaterThan('age', 17).find();
```

It works with boxes written by Hive and by `hive_ce`, encrypted or not, and
with boxes your app has already opened (they stay open).

### Options

| Option | What it does |
| --- | --- |
| `collection: (box) => 'name'` | Store a box under another collection. Return `null` to keep the keys as they are. |
| `cipher` / `ciphers` | The `HiveAesCipher` of an encrypted box, for all boxes or one per box. |
| `convert` | Turn your own objects into maps. Runs for every value. Return `ReaxMigrate.skip` to leave an entry out. |
| `skipExisting` | Leave keys that already exist in ReaxDB alone. |
| `verify` | Read every entry back and compare (default: true). |
| `deleteHiveBoxes` | Delete a box from disk once it migrated completely and verified. |
| `onProgress` | Called after every batch, for a progress bar. |
| `directory` | Where the box files are, if Hive was not initialized there. |
| `inMemoryLimitBytes` | Boxes up to this size (16 MB) are read whole, which is faster. |

### Your own objects

Objects stored with a `TypeAdapter` are migrated as maps. If the class has
a `toJson()` method, it is used. Otherwise pass `convert`:

```dart
final report = await ReaxMigrate.fromHive(
  ['pets'],
  into: db,
  convert: (source, key, value) => value is Pet
      ? {'name': value.name, 'age': value.age}
      : value,
);
```

An object with neither is reported as failed, and the rest of the box still
migrates.

### What values become

ReaxDB stores strings, numbers, booleans, null, bytes, and maps and lists
of those. Other Hive values are converted:

| Hive value | Stored as |
| --- | --- |
| `DateTime` | ISO 8601 string, such as `2026-11-20T08:30:00.000Z` |
| `Duration` | microseconds |
| `BigInt` | string |
| `Set` | list |
| `Map` with int keys | map with string keys |
| enum | its name |

## From SharedPreferences

```dart
final report = await ReaxMigrate.fromSharedPreferences(into: db);
// prefs:theme, prefs:launches, ...
```

Values saved with `SharedPreferencesAsync` or `SharedPreferencesWithCache`
are kept in a different place on Android; use
`ReaxMigrate.fromSharedPreferencesAsync(into: db)` for those.

Pass `keys: {'theme', 'locale'}` to migrate only some keys, and
`removeAfter: true` to remove them from SharedPreferences once migrated and
verified.

## Reading the report

```dart
if (!report.isComplete) {
  for (final source in report.sources) {
    for (final failure in source.failures) {
      print('${failure.source} ${failure.key}: ${failure.error}');
    }
  }
}
```

An entry that cannot be read, converted or stored is reported and does not
stop the migration. An error writing to ReaxDB, such as a full disk, stops
it; free the space and run it again.

## How long it takes

Measured on an Apple M5 Pro, with entries of about 130 bytes, including
verification:

| Entries | Box size | Read | Time |
| ---: | ---: | --- | ---: |
| 100,000 | 13 MB | whole | about 11 s |
| 1,000,000 | 130 MB | one value at a time | about 4 minutes |

Most of the time on large boxes goes into reading Hive one value at a time.
Pass `verify: false` to roughly halve it.

## A typical migration

Run it once, the first time the new version of your app starts:

```dart
final db = await ReaxFlutter.open('app');
if (await db.get<bool>('migrated_from_hive') != true) {
  final report = await ReaxMigrate.fromHive(
    ['users', 'settings'],
    into: db,
    deleteHiveBoxes: true,
  );
  if (report.isComplete) await db.put('migrated_from_hive', true);
}
```

If it is interrupted, the flag is not set, and the next start runs it again.

## License

MIT. See [LICENSE](LICENSE).
