/// Turning values from other stores into values ReaxDB can store.
library;

import 'dart:typed_data';

/// Converts [value] into a value ReaxDB can store, or throws
/// [UnsupportedError] when there is no faithful conversion.
///
/// ReaxDB stores `null`, `bool`, `int`, `double`, `String`, bytes, and maps
/// and lists of those. Values Hive can hold beyond that are converted:
///
/// | From | To |
/// | --- | --- |
/// | `DateTime` | ISO 8601 string (`toIso8601String`) |
/// | `Duration` | microseconds (`int`) |
/// | `BigInt` | decimal string |
/// | `Enum` | its `name` |
/// | `Set`, other `Iterable` | list |
/// | `Map` with non-string keys | map with the keys as strings |
/// | object with a `toJson()` method | its converted `toJson()` result |
///
/// Lists and maps are converted element by element. Anything else (for
/// example a Hive object without `toJson`) throws: pass a `convert` callback
/// to the migration for those.
Object? toStorableValue(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is Uint8List) return value;
  if (value is DateTime) return value.toIso8601String();
  if (value is Duration) return value.inMicroseconds;
  if (value is BigInt) return value.toString();
  if (value is Enum) return value.name;
  if (value is List<int>) return List<int>.of(value);
  if (value is Map) {
    return <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> entry in value.entries)
        '${entry.key}': toStorableValue(entry.value),
    };
  }
  if (value is Iterable) {
    return <dynamic>[
      for (final Object? element in value) toStorableValue(element),
    ];
  }
  final Object? json;
  try {
    json = (value as dynamic).toJson();
  } on NoSuchMethodError {
    throw UnsupportedError(
      'No conversion for a ${value.runtimeType}. Pass a convert callback '
      'that returns a map, a list or a primitive for it.',
    );
  }
  return toStorableValue(json);
}
