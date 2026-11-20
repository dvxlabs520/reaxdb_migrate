## 0.1.0

First release.

- `ReaxMigrate.fromHive(boxes, into: db)` copies Hive boxes (Hive or
  hive_ce, encrypted or not, open or closed) into ReaxDB collections. Small
  boxes are read whole and large ones one value at a time, writes go in
  atomic batches, and running it again is safe.
- `ReaxMigrate.fromSharedPreferences` and `fromSharedPreferencesAsync` copy
  SharedPreferences values.
- Every migration can verify the copy, report progress, convert custom
  objects (`toJson()` or a `convert` callback), skip entries, keep existing
  keys, and delete the source once complete.
- `toStorableValue` converts `DateTime`, `Duration`, `BigInt`, `Set`, enums
  and maps with non-string keys into values ReaxDB stores.
- Needs `reaxdb_dart` 2.7.0.
