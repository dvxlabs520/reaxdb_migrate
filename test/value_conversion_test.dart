import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaxdb_migrate/reaxdb_migrate.dart';

enum Color { red }

class WithJson {
  Map<String, dynamic> toJson() => <String, dynamic>{'at': DateTime.utc(2026)};
}

class Opaque {}

void main() {
  test('primitives and bytes pass through', () {
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2]);
    expect(toStorableValue(null), isNull);
    expect(toStorableValue(true), isTrue);
    expect(toStorableValue(3), 3);
    expect(toStorableValue(1.5), 1.5);
    expect(toStorableValue('s'), 's');
    expect(identical(toStorableValue(bytes), bytes), isTrue);
  });

  test('other Hive types become storable values', () {
    expect(
      toStorableValue(DateTime.utc(2026, 1, 2)),
      '2026-01-02T00:00:00.000Z',
    );
    expect(toStorableValue(const Duration(seconds: 2)), 2000000);
    expect(toStorableValue(BigInt.from(10).pow(30)), '1${'0' * 30}');
    expect(toStorableValue(Color.red), 'red');
    expect(toStorableValue(<int>{3, 4}), <int>[3, 4]);
    expect(
      toStorableValue(<int, Object>{1: DateTime.utc(2026)}),
      <String, dynamic>{'1': '2026-01-01T00:00:00.000Z'},
    );
    expect(toStorableValue(WithJson()), <String, dynamic>{
      'at': '2026-01-01T00:00:00.000Z',
    });
  });

  test('a type without a conversion says what to do', () {
    expect(
      () => toStorableValue(Opaque()),
      throwsA(
        isA<UnsupportedError>().having(
          (UnsupportedError e) => e.message,
          'message',
          contains('convert'),
        ),
      ),
    );
  });
}
