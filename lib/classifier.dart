/// SignVoice — ISL sign classifier (pure Dart, no platform dependencies).
///
/// This is a faithful port of the classifier in the ISL Sign-to-Voice web
/// prototype (`~/workspace/isl_sign_voice/app.js`). It MUST stay behaviour-
/// compatible with the JS version so that sample files (starter model and
/// teach-mode exports) are interchangeable between the web prototype and
/// this app.
///
/// Canonical feature layout (identical to app.js and
/// tools/build_starter_model.py):
///   vec = [leftPresent, rightPresent, ...leftHand(21*3), ...rightHand(21*3)]
///   = 128 floats. Per hand: subtract wrist, divide by max 2D wrist
///   distance.
/// The distance compares (x, y) only; z is stored for future versions.
/// The distance is alignment-aware: it tries same-slot, cross-slot and
/// mirrored hand matches, so one-hand data of unknown handedness (like the
/// starter model) still matches live signing with either hand.
library;

import 'dart:math' as math;

/// Total feature-vector length.
const int kDim = 128;

/// Offset of the left-hand block inside the vector.
const int kLeftOff = 2;

/// Offset of the right-hand block inside the vector.
const int kRightOff = 65;

/// Number of neighbours that vote in the kNN step.
const int kNeighbours = 7;

/// Nearest-sample distance above this counts as "no match".
const double kMaxMatchDist = 0.62;

/// Penalty added when live and sample disagree on hand count.
const double kMissingHandPenalty = 0.45;

/// One 3D landmark point (MediaPipe-style normalised coordinates).
class LandmarkPoint {
  final double x;
  final double y;
  final double z;
  const LandmarkPoint(this.x, this.y, this.z);
}

/// A classified prediction: winning [label], vote-share [confidence]
/// (0..1), and the [distance] of the single nearest sample.
class Prediction {
  final String label;
  final double confidence;
  final double distance;
  const Prediction(this.label, this.confidence, this.distance);

  @override
  String toString() =>
      'Prediction($label, ${(confidence * 100).toStringAsFixed(1)}%, '
      'd=${distance.toStringAsFixed(3)})';
}

/// Normalise one hand's 21 landmarks exactly like app.js `normaliseHand`:
/// subtract the wrist, divide by the max 2D wrist distance. Returns a flat
/// 63-float block, or null when the input is unusable.
List<double>? normaliseHand(List<LandmarkPoint>? landmarks) {
  if (landmarks == null || landmarks.length != 21) return null;
  final w = landmarks[0];
  final rel = List<List<double>>.generate(
    21,
    (i) => [landmarks[i].x - w.x, landmarks[i].y - w.y, landmarks[i].z - w.z],
  );
  var scale = 0.0;
  for (final r in rel) {
    scale = math.max(scale, math.sqrt(r[0] * r[0] + r[1] * r[1]));
  }
  if (scale < 1e-6) return null;
  final out = List<double>.filled(63, 0.0);
  for (var i = 0; i < 21; i++) {
    out[i * 3] = rel[i][0] / scale;
    out[i * 3 + 1] = rel[i][1] / scale;
    out[i * 3 + 2] = rel[i][2] / scale;
  }
  return out;
}

/// Build the canonical 128-float feature vector from the two hands'
/// landmarks (either may be null), mirroring app.js `makeVector`.
List<double> makeVector(
  List<LandmarkPoint>? leftLandmarks,
  List<LandmarkPoint>? rightLandmarks,
) {
  final vec = List<double>.filled(kDim, 0.0);
  final l = normaliseHand(leftLandmarks);
  final r = normaliseHand(rightLandmarks);
  if (l != null) {
    vec[0] = 1;
    for (var i = 0; i < 63; i++) {
      vec[kLeftOff + i] = l[i];
    }
  }
  if (r != null) {
    vec[1] = 1;
    for (var i = 0; i < 63; i++) {
      vec[kRightOff + i] = r[i];
    }
  }
  return vec;
}

/// Slice one 63-float hand block out of a feature vector.
List<double> handBlock(List<double> vec, int off) => vec.sublist(off, off + 63);

/// Mirror a hand block (negate x). After wrist-centring, a mirrored left
/// hand looks like a right hand.
List<double> mirrorHand(List<double> h) {
  final m = List<double>.from(h);
  for (var i = 0; i < 21; i++) {
    m[i * 3] = -m[i * 3];
  }
  return m;
}

/// Mean per-point 2D distance between two hand blocks ((x, y) only).
double handDist(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < 21; i++) {
    final dx = a[i * 3] - b[i * 3];
    final dy = a[i * 3 + 1] - b[i * 3 + 1];
    s += math.sqrt(dx * dx + dy * dy);
  }
  return s / 21;
}

/// Cost of matching hand [a] to hand [b]; a mirror flip is allowed.
double pairCost(List<double> a, List<double> b) =>
    math.min(handDist(a, b), handDist(a, mirrorHand(b)));

/// Alignment-aware distance between a live vector and a sample vector.
/// Mirrors app.js `vecDistance` exactly, including the 0.5 presence-flag
/// threshold and the missing-hand penalty.
double vecDistance(List<double> live, List<double> sample) {
  final lL = live[0] > 0.5 ? handBlock(live, kLeftOff) : null;
  final lR = live[1] > 0.5 ? handBlock(live, kRightOff) : null;
  final sL = sample[0] > 0.5 ? handBlock(sample, kLeftOff) : null;
  final sR = sample[1] > 0.5 ? handBlock(sample, kRightOff) : null;
  final l = [lL, lR].whereType<List<double>>().toList();
  final s = [sL, sR].whereType<List<double>>().toList();
  if (l.isEmpty || s.isEmpty) return double.infinity;

  if (l.length == 1 && s.length == 1) return pairCost(l[0], s[0]);

  if (l.length == 2 && s.length == 2) {
    final slotwise = (pairCost(l[0], s[0]) + pairCost(l[1], s[1])) / 2;
    final swapped =
        (pairCost(l[0], mirrorHand(s[1])) + pairCost(l[1], mirrorHand(s[0]))) / 2;
    return math.min(slotwise, swapped);
  }

  // Unequal hand counts: best single-hand match + a fixed penalty, so a
  // true two-hand match beats a one-hand approximation, while one-hand
  // samples still rank correctly against each other.
  var best = double.infinity;
  for (final lh in l) {
    for (final sh in s) {
      best = math.min(best, pairCost(lh, sh));
    }
  }
  return best + kMissingHandPenalty;
}

/// The sample store + kNN classifier.
///
/// Holds label -> list of 128-float sample vectors, loaded from the same
/// JSON shape the web prototype uses:
/// `{ "labels": { "A": {"samples": [[...], ...]} , "B": [[...], ...] } }`
/// (an entry may be a plain array or an object with a `samples` array —
/// exactly the two shapes app.js `rebuildStore` accepts).
class SignClassifier {
  final Map<String, List<List<double>>> _store = {};
  final Set<String> _excludedLabels = {};

  /// Labels currently excluded (mirrors the web prototype's delete-a-sign).
  Set<String> get excludedLabels => Set.unmodifiable(_excludedLabels);

  /// All labels with at least one usable sample, sorted.
  List<String> get labels => _store.keys.toList()..sort();

  /// Total number of samples across all labels.
  int get sampleCount => _store.values.fold(0, (n, arr) => n + arr.length);

  /// Number of samples stored for [label].
  int sampleCountFor(String label) => _store[label]?.length ?? 0;

  void _add(String label, List<List<double>> samples) {
    if (_excludedLabels.contains(label)) return;
    final list = _store.putIfAbsent(label, () => <List<double>>[]);
    for (final s in samples) {
      if (s.length == kDim) list.add(List<double>.from(s));
    }
  }

  /// Rebuild the store from starter-model JSON plus user-taught samples,
  /// mirroring app.js `rebuildStore`. [starterLabels] is the decoded
  /// `labels` object of a samples JSON file; [userSamples] maps label ->
  /// sample vectors recorded on this device (teach mode).
  void rebuildStore({
    Map<String, dynamic>? starterLabels,
    Map<String, List<List<double>>> userSamples = const {},
  }) {
    _store.clear();
    if (starterLabels != null) {
      for (final entry in starterLabels.entries) {
        _add(entry.key, _extractSamples(entry.value));
      }
    }
    for (final entry in userSamples.entries) {
      _add(entry.key, entry.value);
    }
  }

  static List<List<double>> _extractSamples(dynamic entry) {
    final raw = entry is List
        ? entry
        : (entry is Map ? entry['samples'] : null);
    if (raw is! List) return const [];
    return raw
        .whereType<List>()
        .map((v) => v.map((n) => (n as num).toDouble()).toList())
        .where((v) => v.length == kDim)
        .toList();
  }

  /// Add samples for [label] (teach mode). Re-includes a label that was
  /// previously excluded, matching app.js `finishTeach`.
  void addUserSamples(String label, List<List<double>> samples) {
    _excludedLabels.remove(label);
    _add(label, samples);
  }

  /// Remove [label] from the active store and exclude it from future
  /// rebuilds until it is re-taught, matching the web prototype's chip
  /// delete.
  void excludeLabel(String label) {
    _store.remove(label);
    _excludedLabels.add(label);
  }

  /// Classify a 128-float feature vector with the alignment-aware
  /// weighted kNN from app.js `classify`. Returns null for "no match"
  /// (empty store, or nearest sample farther than [kMaxMatchDist]).
  Prediction? classify(List<double> vec) {
    final scored = <(double, String)>[];
    _store.forEach((label, samples) {
      for (final s in samples) {
        scored.add((vecDistance(vec, s), label));
      }
    });
    if (scored.isEmpty) return null;
    // JS Array.sort is stable, Dart's is not: break distance ties by
    // insertion order so neighbour selection matches the web prototype.
    final indexed = <(double, String, int)>[
      for (var i = 0; i < scored.length; i++) (scored[i].$1, scored[i].$2, i),
    ];
    indexed.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$3.compareTo(b.$3);
    });
    scored.setAll(0, indexed.map((e) => (e.$1, e.$2)));
    if (scored[0].$1 > kMaxMatchDist) return null;
    final k = math.min(kNeighbours, scored.length);
    final votes = <String, double>{};
    var wSum = 0.0;
    for (var i = 0; i < k; i++) {
      final w = 1 / (scored[i].$1 + 0.02);
      votes[scored[i].$2] = (votes[scored[i].$2] ?? 0) + w;
      wSum += w;
    }
    String? bestLabel;
    var bestW = -1.0;
    votes.forEach((label, w) {
      if (w > bestW) {
        bestW = w;
        bestLabel = label;
      }
    });
    if (bestLabel == null) return null;
    return Prediction(bestLabel!, bestW / wSum, scored[0].$1);
  }
}

/// Temporal smoothing + hold-to-add, ported from app.js.
///
/// Raw per-frame predictions are jittery; the web prototype majority-votes
/// over a 900 ms window and only commits a sign to the sentence after it
/// has been stable for 700 ms, and then requires the sign to change/clear
/// before the same label can be added again ("release"). Feed it one
/// [observe] call per classified frame; it calls [onCommit] when a sign
/// should be appended to the sentence.
class PredictionSmoother {
  static const int smoothWindowMs = 900;
  static const int holdMs = 700;

  final void Function(String label) onCommit;
  final List<({String? label, double conf, int t})> _history = [];
  String? _stableLabel;
  int _stableSince = 0;
  String? _lastAdded;
  bool _needRelease = false;

  PredictionSmoother({required this.onCommit});

  /// The label currently considered stable (for UI display), if any.
  String? get stableLabel => _stableLabel;

  Prediction? _smoothed(int now) {
    _history.removeWhere((h) => now - h.t >= smoothWindowMs);
    final counts = <String, int>{};
    var total = 0;
    for (final h in _history) {
      final label = h.label;
      if (label == null) continue;
      counts[label] = (counts[label] ?? 0) + 1;
      total++;
    }
    String? best;
    var bestN = 0;
    counts.forEach((label, n) {
      if (n > bestN) {
        bestN = n;
        best = label;
      }
    });
    if (best == null || total < 4 || bestN / total < 0.6) return null;
    final confs = _history
        .where((h) => h.label == best)
        .map((h) => h.conf)
        .toList();
    final avg = confs.reduce((a, b) => a + b) / confs.length;
    return Prediction(best!, avg, 0);
  }

  /// Observe one frame's raw prediction ([pred] may be null) at time [now]
  /// (milliseconds, any monotonic clock). Fires [onCommit] when a sign has
  /// been held steady long enough.
  void observe(Prediction? pred, int now) {
    _history.add((label: pred?.label, conf: pred?.confidence ?? 0, t: now));
    final sm = _smoothed(now);
    if (sm == null) {
      _stableLabel = null;
      _needRelease = false;
      return;
    }
    if (sm.label != _lastAdded) _needRelease = false;
    if (sm.label != _stableLabel) {
      _stableLabel = sm.label;
      _stableSince = now;
    }
    if (!_needRelease && now - _stableSince >= holdMs) {
      onCommit(sm.label);
      _lastAdded = sm.label;
      _needRelease = true;
      _stableSince = now;
    }
  }

  /// Forget all smoothing state (e.g. when leaving the camera screen).
  void reset() {
    _history.clear();
    _stableLabel = null;
    _lastAdded = null;
    _needRelease = false;
  }
}

/// Sentence assembly, mirroring app.js: a single-character label is a
/// fingerspelled letter and is appended directly; a longer label is a word
/// and is space-separated.
class SentenceBuilder {
  String _text = '';

  String get text => _text;

  void append(String label) {
    if (label.length == 1) {
      _text += label;
    } else {
      if (_text.isNotEmpty && !_text.endsWith(' ')) _text += ' ';
      _text += label;
    }
  }

  void addSpace() => _text += ' ';

  void backspace() {
    if (_text.isNotEmpty) _text = _text.substring(0, _text.length - 1);
  }

  void clear() => _text = '';
}
