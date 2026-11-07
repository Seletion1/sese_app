/// Small, dependency-free coercion helpers for values read from Firestore,
/// REST payloads, and local caches.
///
/// Why these exist
/// ───────────────
/// Firebase documents from this codebase are written from many surfaces
/// (client SDKs, Cloud Functions, Hub tools) over several years. Numeric
/// fields are stored inconsistently — `int`, `double`, occasionally
/// `"4100"` as a string. A plain `value as num` is a runtime crash on
/// those documents and it took down the whole notification inbox and the
/// order feed in production. `as num?` is only safe if the value is
/// genuinely null or a number — never for strings.
///
/// All helpers tolerate `null`, `num`, and numeric strings, and unwrap
/// `{value: <number>}` JSON wrappers produced by some API responses.
/// Non-numeric / unparseable values return `null` — they must never throw.

library;

/// Returns [v] if it is a number, parses numeric strings, unwraps
/// `{value: …}` JSON wrappers. Returns null for null/non-numeric input.
num? safeNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  if (v is Map && v['value'] != null) return safeNum(v['value']);
  return null;
}

/// Convenience: [safeNum] as double, or null if unparseable.
double? safeDouble(dynamic v) => safeNum(v)?.toDouble();

/// Convenience: [safeNum] as int, or null if unparseable. Truncates doubles.
int? safeInt(dynamic v) => safeNum(v)?.toInt();

/// Convenience: [safeNum] or [fallback] when unparseable (defaults 0).
double doubleOr(dynamic v, {double fallback = 0.0}) => safeDouble(v) ?? fallback;

/// Convenience: [safeNum] or [fallback] when unparseable (defaults 0).
int intOr(dynamic v, {int fallback = 0}) => safeInt(v) ?? fallback;

/// Returns [v] as a trimmed [String], or [fallback] if null/empty.
String safeString(dynamic v, {String fallback = ''}) {
  if (v == null) return fallback;
  final s = v.toString().trim();
  return s.isEmpty ? fallback : s;
}

/// Coerces [v] to a boolean safely. Tolerates booleans, numeric 1/0, and 'true'/'false' strings.
bool safeBool(dynamic v, {bool fallback = false}) {
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final lower = v.trim().toLowerCase();
    if (lower == 'true' || lower == '1' || lower == 'yes') return true;
    if (lower == 'false' || lower == '0' || lower == 'no') return false;
  }
  return fallback;
}

/// Parses [v] to a [DateTime] safely. Tolerates Firestore Timestamps (via toDate), ISO strings, and millisecond timestamps.
DateTime? safeDateTime(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  // Handle Firestore Timestamp dynamically without hard coupling
  try {
    final dynamic timestamp = v;
    if (timestamp.toDate != null && timestamp.toDate is Function) {
      return (timestamp.toDate() as DateTime);
    }
  } catch (_) {}
  if (v is num) {
    // If in seconds (under 10 billion), convert to ms
    final ms = v < 10000000000 ? (v * 1000).toInt() : v.toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  if (v is String) {
    return DateTime.tryParse(v.trim());
  }
  return null;
}

/// Safely casts or maps a dynamic value to a [List<T>]. Never throws.
List<T> safeList<T>(dynamic v, [T Function(dynamic item)? mapper]) {
  if (v == null || v is! Iterable) return <T>[];
  final list = <T>[];
  for (final item in v) {
    if (mapper != null) {
      try {
        final mapped = mapper(item);
        list.add(mapped);
      } catch (_) {}
    } else if (item is T) {
      list.add(item);
    }
  }
  return list;
}

/// Safely extracts a [Map<String, dynamic>] from [v]. Returns empty map if invalid.
Map<String, dynamic> safeMap(dynamic v) {
  if (v == null || v is! Map) return <String, dynamic>{};
  return Map<String, dynamic>.from(v);
}

