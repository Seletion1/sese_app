/// Safe collection access extensions for crash-resilient Flutter applications.
///
/// Prevents unhandled [StateError] exceptions from blind calls to [Iterable.first],
/// [Iterable.last], [Iterable.single], or index-out-of-bounds access.
library;

/// Extension providing null-safe accessors on [List].
extension SafeListAccess<T> on List<T> {
  /// Returns the first element, or null if the list is empty.
  T? get firstOrNull => isEmpty ? null : first;

  /// Returns the last element, or null if the list is empty.
  T? get lastOrNull => isEmpty ? null : last;

  /// Returns the single element if [length] == 1, or null otherwise.
  T? get singleOrNull => (length == 1) ? single : null;

  /// Returns the element at [index], or null if out of range.
  T? getOrNull(int index) => (index >= 0 && index < length) ? this[index] : null;

  /// Returns the first element satisfying [test], or null if none found.
  T? firstWhereOrNull(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}

/// Extension providing null-safe accessors on any [Iterable].
extension SafeIterableAccess<T> on Iterable<T> {
  /// Returns the first element, or null if empty.
  T? get safeFirst => isEmpty ? null : first;

  /// Returns the last element, or null if empty.
  T? get safeLast => isEmpty ? null : last;

  /// Returns the single element if exactly 1 element exists, or null.
  T? get safeSingle => (length == 1) ? single : null;

  /// Safe firstWhere that never throws [StateError].
  T? safeFirstWhere(bool Function(T element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
