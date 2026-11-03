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
