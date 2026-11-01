/// One order for model lists: by family (name, case-insensitive), then by
/// version, newest first, so "GLM-5.3" comes before "GLM-5-Turbo" and both
/// before "GLM-4.7". Numbers are compared as numbers, and a number sorts
/// before a word at the same place.
int compareModelNames(String a, String b) {
  final x = _chunks(a), y = _chunks(b);
  for (var i = 0; i < x.length && i < y.length; i++) {
    final p = x[i], q = y[i];
    final pn = int.tryParse(p), qn = int.tryParse(q);
    if (pn != null && qn != null) {
      if (pn != qn) return qn.compareTo(pn);
    } else if (pn != null) {
      return -1;
    } else if (qn != null) {
      return 1;
    } else if (p != q) {
      return p.compareTo(q);
    }
  }
  return x.length.compareTo(y.length);
}

final _part = RegExp(r'\d+|[^\W\d_]+');

List<String> _chunks(String name) => [
  for (final m in _part.allMatches(name.toLowerCase())) m.group(0)!,
];
