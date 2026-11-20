@Tags(<String>['large'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:reaxdb_dart/reaxdb_dart.dart';
import 'package:reaxdb_migrate/reaxdb_migrate.dart';

/// A million entries, to show that memory does not follow the box size.
/// Run with: flutter test --tags large --run-skipped
void main() {
  // 100,000 entries make a box of about 13 MB, read whole; 1,000,000 make
  // one of about 130 MB, over the default limit, read value by value.
  for (final int count in <int>[100000, 1000000]) {
    test('$count entries migrate and verify', () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'migrate_1m_',
      );
      Hive.init('${root.path}/hive');
      try {
        final LazyBox<dynamic> writer = await Hive.openLazyBox<dynamic>('big');
        for (int start = 0; start < count; start += 10000) {
          await writer.putAll(<dynamic, dynamic>{
            for (int i = start; i < start + 10000; i++)
              'item$i': <String, dynamic>{'n': i, 'payload': 'x' * 100},
          });
        }
        await writer.close();

        final ReaxDB db = await ReaxDB.open(
          path: '${root.path}/reax',
          syncMode: SyncMode.none,
        );
        final int rssBefore = ProcessInfo.currentRss;
        int peak = rssBefore;
        final Stopwatch clock = Stopwatch()..start();
        final MigrateReport report = await ReaxMigrate.fromHive(
          <String>['big'],
          into: db,
          batchSize: 2000,
          onProgress: (_) {
            final int rss = ProcessInfo.currentRss;
            if (rss > peak) peak = rss;
          },
        );
        clock.stop();
        // ignore: avoid_print
        print(
          '$report\n'
          'time: ${clock.elapsed.inSeconds} s, '
          'RSS before: ${rssBefore ~/ (1 << 20)} MB, '
          'peak during migration: ${peak ~/ (1 << 20)} MB',
        );
        expect(report.isComplete, isTrue);
        expect(report.imported, count);
        await db.close();
      } finally {
        await Hive.close();
        await root.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  }
}
