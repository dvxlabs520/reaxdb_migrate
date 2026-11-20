import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:reaxdb_migrate/reaxdb_migrate.dart';

/// A type the app stores with a TypeAdapter and that has no toJson.
class Pet {
  Pet(this.name, this.age);
  final String name;
  final int age;
}

class PetAdapter extends TypeAdapter<Pet> {
  @override
  final int typeId = 201;

  @override
  Pet read(BinaryReader reader) => Pet(reader.readString(), reader.readInt());

  @override
  void write(BinaryWriter writer, Pet obj) {
    writer
      ..writeString(obj.name)
      ..writeInt(obj.age);
  }
}

/// A type with a TypeAdapter and a toJson method.
class Note {
  Note(this.text);
  final String text;
  Map<String, dynamic> toJson() => <String, dynamic>{'text': text};
}

class NoteAdapter extends TypeAdapter<Note> {
  @override
  final int typeId = 202;

  @override
  Note read(BinaryReader reader) => Note(reader.readString());

  @override
  void write(BinaryWriter writer, Note obj) => writer.writeString(obj.text);
}

void main() {
  late Directory root;
  late ReaxDB db;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(201)) Hive.registerAdapter(PetAdapter());
    if (!Hive.isAdapterRegistered(202)) Hive.registerAdapter(NoteAdapter());
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reaxdb_migrate_hive_');
    Hive.init('${root.path}/hive');
    db = await ReaxDB.open(path: '${root.path}/reax', syncMode: SyncMode.none);
  });

  tearDown(() async {
    await Hive.close();
    await ReaxDB.closeAll();
    await root.delete(recursive: true);
  });

  /// Writes [entries] to a box on disk and closes it, like an app that
  /// stored data with Hive in a previous version.
  Future<void> hiveBox(
    String name,
    Map<dynamic, dynamic> entries, {
    HiveCipher? cipher,
  }) async {
    final Box<dynamic> box = await Hive.openBox<dynamic>(
      name,
      encryptionCipher: cipher,
    );
    await box.putAll(entries);
    await box.close();
  }

  test('copies a box into a collection, string and int keys', () async {
    await hiveBox('users', <dynamic, dynamic>{
      'ada': <String, dynamic>{'name': 'Ada', 'age': 36},
      42: 'answer',
    });

    final MigrateReport report = await ReaxMigrate.fromHive(<String>[
      'users',
    ], into: db);

    expect(report.isComplete, isTrue, reason: '$report');
    expect(report.imported, 2);
    final SourceReport users = report.sources.single;
    expect(users.source, 'hive:users');
    expect(users.total, 2);
    expect(users.verification!.checked, 2);
    expect(await db.get<Map<String, dynamic>>('users:ada'), <String, dynamic>{
      'name': 'Ada',
      'age': 36,
    });
    expect(await db.get<String>('users:42'), 'answer');
    // Queries work on the migrated documents.
    expect(await db.query('users').whereEquals('age', 36).count(), 1);
    // A box it opened itself is closed again.
    expect(Hive.isBoxOpen('users'), isFalse);
  });

  test('a large box migrates with progress and verifies', () async {
    const int count = 100000;
    await hiveBox('big', <dynamic, dynamic>{
      for (int i = 0; i < count; i++)
        'item$i': <String, dynamic>{'n': i, 'even': i.isEven},
    });

    final List<MigrationProgress> progress = <MigrationProgress>[];
    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['big'],
      into: db,
      batchSize: 1000,
      onProgress: progress.add,
    );

    expect(report.isComplete, isTrue, reason: '$report');
    expect(report.imported, count);
    expect(report.sources.single.verification!.checked, count);
    expect(progress, isNotEmpty);
    expect(progress.last.processed, count);
    expect(progress.last.fraction, 1);
    final List<int> steps = <int>[
      for (final MigrationProgress p in progress) p.processed,
    ];
    expect(steps, orderedEquals(List<int>.of(steps)..sort()));
    expect(
      await db.get<Map<String, dynamic>>('big:item99999'),
      <String, dynamic>{'n': 99999, 'even': false},
    );
    expect((await db.info()).entryCount, count);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a box over the in-memory limit is read value by value', () async {
    await hiveBox('lazy', <dynamic, dynamic>{
      for (int i = 0; i < 2000; i++) 'k$i': <String, dynamic>{'n': i},
    });
    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['lazy'],
      into: db,
      inMemoryLimitBytes: 0,
    );
    expect(report.isComplete, isTrue, reason: '$report');
    expect(report.sources.single.verification!.checked, 2000);
    expect(await db.get<Map<String, dynamic>>('lazy:k1999'), <String, dynamic>{
      'n': 1999,
    });
    expect(Hive.isBoxOpen('lazy'), isFalse);
  });

  test('several boxes, each into its own collection', () async {
    await hiveBox('a', <dynamic, dynamic>{'x': 1, 'y': 2});
    await hiveBox('b', <dynamic, dynamic>{'x': 3});
    final List<MigrationProgress> progress = <MigrationProgress>[];

    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['a', 'b'],
      into: db,
      collection: (String box) => 'imported_$box',
      onProgress: progress.add,
    );

    expect(report.sources.map((SourceReport s) => s.source), <String>[
      'hive:a',
      'hive:b',
    ]);
    expect(progress.map((MigrationProgress p) => p.sourceIndex).toSet(), <int>{
      0,
      1,
    });
    expect(progress.every((MigrationProgress p) => p.sourceCount == 2), isTrue);
    expect(await db.get<int>('imported_a:y'), 2);
    expect(await db.get<int>('imported_b:x'), 3);
  });

  test('keys can be kept as they are', () async {
    await hiveBox('settings', <dynamic, dynamic>{'theme': 'dark'});
    await ReaxMigrate.fromHive(
      <String>['settings'],
      into: db,
      collection: (_) => null,
    );
    expect(await db.get<String>('theme'), 'dark');
  });

  test('an encrypted box needs its cipher', () async {
    final HiveAesCipher cipher = HiveAesCipher(
      List<int>.generate(32, (int i) => i),
    );
    await hiveBox('secret', <dynamic, dynamic>{'pin': '1234'}, cipher: cipher);

    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['secret'],
      into: db,
      ciphers: <String, HiveCipher>{'secret': cipher},
    );
    expect(report.isComplete, isTrue);
    expect(await db.get<String>('secret:pin'), '1234');
  });

  test('boxes the app already opened are read and left open', () async {
    final Box<dynamic> box = await Hive.openBox<dynamic>('open_box');
    await box.put('k', 'v');
    final LazyBox<dynamic> lazy = await Hive.openLazyBox<dynamic>('open_lazy');
    await lazy.put('k', 'lazy');

    final MigrateReport report = await ReaxMigrate.fromHive(<String>[
      'open_box',
      'open_lazy',
    ], into: db);

    expect(report.isComplete, isTrue);
    expect(await db.get<String>('open_box:k'), 'v');
    expect(await db.get<String>('open_lazy:k'), 'lazy');
    expect(box.isOpen, isTrue);
    expect(lazy.isOpen, isTrue);
  });

  test('values ReaxDB cannot hold as they are are converted', () async {
    await hiveBox('types', <dynamic, dynamic>{
      'date': DateTime.utc(2026, 11, 20, 8, 30),
      'big': BigInt.parse('123456789012345678901234567890'),
      'set': <String>{'a', 'b'},
      'intKeys': <int, String>{1: 'one', 2: 'two'},
      'scores': <int>[1000, -1, 7],
      'bytes': Uint8List.fromList(<int>[1, 2, 3]),
      'nested': <String, dynamic>{
        'when': DateTime.utc(2026),
        'tags': <String>['x'],
      },
      'note': Note('hello'),
    });

    final MigrateReport report = await ReaxMigrate.fromHive(<String>[
      'types',
    ], into: db);

    expect(report.isComplete, isTrue, reason: '$report');
    expect(await db.get<String>('types:date'), '2026-11-20T08:30:00.000Z');
    expect(await db.get<String>('types:big'), '123456789012345678901234567890');
    expect(await db.get<List<dynamic>>('types:set'), <String>['a', 'b']);
    expect(
      await db.get<Map<String, dynamic>>('types:intKeys'),
      <String, dynamic>{'1': 'one', '2': 'two'},
    );
    expect(await db.get<List<dynamic>>('types:scores'), <int>[1000, -1, 7]);
    expect(await db.get<Uint8List>('types:bytes'), <int>[1, 2, 3]);
    expect(
      await db.get<Map<String, dynamic>>('types:nested'),
      <String, dynamic>{
        'when': '2026-01-01T00:00:00.000Z',
        'tags': <String>['x'],
      },
    );
    expect(await db.get<Map<String, dynamic>>('types:note'), <String, dynamic>{
      'text': 'hello',
    });
  });

  test('objects without toJson fail alone, or migrate with convert', () async {
    await hiveBox('pets', <dynamic, dynamic>{'rex': Pet('Rex', 3), 'count': 1});

    final MigrateReport plain = await ReaxMigrate.fromHive(<String>[
      'pets',
    ], into: db);
    final SourceReport pets = plain.sources.single;
    expect(pets.imported, 1);
    expect(pets.failed, 1);
    expect(pets.failures.single.key, 'rex');
    expect(pets.failures.single.error, isA<UnsupportedError>());
    expect(plain.isComplete, isFalse);

    final MigrateReport converted = await ReaxMigrate.fromHive(
      <String>['pets'],
      into: db,
      convert: (String source, Object? key, Object? value) => value is Pet
          ? <String, dynamic>{'name': value.name, 'age': value.age}
          : value,
    );
    expect(converted.isComplete, isTrue);
    expect(await db.get<Map<String, dynamic>>('pets:rex'), <String, dynamic>{
      'name': 'Rex',
      'age': 3,
    });
  });

  test('convert can leave entries out', () async {
    await hiveBox('cache', <dynamic, dynamic>{'keep': 1, 'drop': 2});
    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['cache'],
      into: db,
      convert: (String source, Object? key, Object? value) =>
          key == 'drop' ? ReaxMigrate.skip : value,
      deleteHiveBoxes: true,
    );
    final SourceReport cache = report.sources.single;
    expect(cache.imported, 1);
    expect(cache.skipped, 1);
    expect(await db.exists('cache:drop'), isFalse);
    // Something was left out, so the box is kept.
    expect(cache.deleted, isFalse);
    expect(await Hive.boxExists('cache'), isTrue);
  });

  test('skipExisting keeps the app data and still verifies', () async {
    await db.put('users:ada', 'already here');
    await hiveBox('users', <dynamic, dynamic>{'ada': 'from hive', 'bob': 'b'});

    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['users'],
      into: db,
      skipExisting: true,
    );
    final SourceReport users = report.sources.single;
    expect(users.imported, 1);
    expect(users.skipped, 1);
    expect(users.verification!.passed, isTrue);
    expect(users.verification!.checked, 1);
    expect(await db.get<String>('users:ada'), 'already here');
  });

  test('verification catches a copy that differs', () async {
    await hiveBox('flaky', <dynamic, dynamic>{'k': 1});
    int calls = 0;
    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['flaky'],
      into: db,
      // Returns a different value when read again for verification.
      convert: (String source, Object? key, Object? value) => ++calls,
      deleteHiveBoxes: true,
    );
    final SourceReport flaky = report.sources.single;
    expect(flaky.verification!.mismatched, 1);
    expect(flaky.verification!.mismatchedKeys, <Object?>['k']);
    expect(report.isComplete, isFalse);
    expect(flaky.deleted, isFalse);
  });

  test('a clean migration can delete the boxes', () async {
    await hiveBox('done', <dynamic, dynamic>{'k': 'v'});
    final MigrateReport report = await ReaxMigrate.fromHive(
      <String>['done'],
      into: db,
      deleteHiveBoxes: true,
    );
    expect(report.sources.single.deleted, isTrue);
    expect(await Hive.boxExists('done'), isFalse);
    expect(await db.get<String>('done:k'), 'v');
  });

  test('running it again after a partial migration completes it', () async {
    await hiveBox('resume', <dynamic, dynamic>{
      for (int i = 0; i < 1000; i++) 'k$i': i,
    });
    await ReaxMigrate.fromHive(<String>['resume'], into: db);
    // As if the first run had stopped halfway.
    await db.deleteBatch(<String>[
      for (int i = 500; i < 1000; i++) 'resume:k$i',
    ]);

    final MigrateReport again = await ReaxMigrate.fromHive(<String>[
      'resume',
    ], into: db);
    expect(again.isComplete, isTrue);
    expect((await db.info()).entryCount, 1000);
  });

  test('a collection name must be usable', () async {
    await hiveBox('x', <dynamic, dynamic>{'k': 1});
    await expectLater(
      ReaxMigrate.fromHive(<String>['x'], into: db, collection: (_) => 'a:b'),
      throwsArgumentError,
    );
    await expectLater(
      ReaxMigrate.fromHive(<String>['x'], into: db, collection: (_) => ''),
      throwsArgumentError,
    );
  });
}
