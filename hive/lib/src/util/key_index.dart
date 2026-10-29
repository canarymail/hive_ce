/// Not part of public API
///
/// The ordered key -> value index behind a [Keystore]: the skip list for
/// boxes that hold their values, and a compact array index for lazy boxes.
abstract interface class KeyIndex<K, V> {
  /// Not part of public API
  int get length;

  /// Not part of public API
  Iterable<K> get keys;

  /// Not part of public API
  Iterable<V> get values;

  /// Not part of public API
  V? insert(K key, V? value);

  /// Not part of public API
  V? delete(K key);

  /// Not part of public API
  V? get(K key);

  /// Not part of public API
  Iterable<V> valuesFromKey(K key);

  /// Not part of public API
  V? getAt(int index);

  /// Not part of public API
  K? getKeyAt(int index);

  /// Not part of public API
  void clear();
}
