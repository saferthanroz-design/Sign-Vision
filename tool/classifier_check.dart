/// Standalone verification harness for the Dart classifier port.
///
/// Runs WITHOUT Flutter and WITHOUT writing any files: it loads the web
/// prototype's starter model, feeds stored samples/centroids back through
/// SignClassifier, and prints how often the classifier agrees with the
/// true label — the same style of smoke test the JS prototype was
/// validated with. Also exercises the alignment-aware matching (mirrored
/// hand, cross-slot hand) that the port must preserve.
///
/// Usage: dart tool/classifier_check.dart [path-to-starter_samples.json]
library;

import 'dart:convert';
import 'dart:io';

import '../lib/classifier.dart';
import '../lib/landmark_source.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty
      ? args[0]
      : '/home/hatch/workspace/isl_sign_voice/model/starter_samples.json';
  final decoded =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final labels = decoded['labels'] as Map<String, dynamic>;

  final clf = SignClassifier()..rebuildStore(starterLabels: labels);
  print('store: ${clf.labels.length} labels, ${clf.sampleCount} samples');

  // (a) Each label's own centroid should classify back to that label.
  var centroidHits = 0, centroidTotal = 0;
  final centroidMisses = <String>[];
  labels.forEach((label, entry) {
    final centroid = (entry as Map)['centroid'];
    if (centroid is! List) return;
    centroidTotal++;
    final vec = centroid.map((n) => (n as num).toDouble()).toList();
    final pred = clf.classify(vec);
    if (pred?.label == label) {
      centroidHits++;
    } else {
      centroidMisses.add('$label->${pred?.label}');
    }
  });
  print('centroid self-match: $centroidHits/$centroidTotal'
      '${centroidMisses.isEmpty ? '' : '  misses: ${centroidMisses.join(', ')}'}');

  // (b) Up to 3 stored samples per label should classify back correctly.
  var sampleHits = 0, sampleTotal = 0;
  final sampleMisses = <String>[];
  labels.forEach((label, entry) {
    final samples = (entry as Map)['samples'] as List;
    for (final raw in samples.take(3)) {
      sampleTotal++;
      final vec = (raw as List).map((n) => (n as num).toDouble()).toList();
      final pred = clf.classify(vec);
      if (pred?.label == label) {
        sampleHits++;
      } else {
        sampleMisses.add('$label->${pred?.label}');
      }
    }
  });
  print('sample self-match: $sampleHits/$sampleTotal'
      '${sampleMisses.isEmpty ? '' : '  misses: ${sampleMisses.join(', ')}'}');

  // (c) Alignment awareness: mirror the present hand of an 'A' sample and
  // move it to the other slot; the label must survive both transforms.
  final aSamples = (labels['A'] as Map)['samples'] as List;
  final a0 = (aSamples.first as List).map((n) => (n as num).toDouble()).toList();
  final presentOff = a0[0] > 0.5 ? kLeftOff : kRightOff;
  final otherOff = presentOff == kLeftOff ? kRightOff : kLeftOff;
  final hand = handBlock(a0, presentOff);

  final mirrored = List<double>.filled(kDim, 0.0);
  mirrored[presentOff == kLeftOff ? 0 : 1] = 1;
  mirrored.setRange(presentOff, presentOff + 63, mirrorHand(hand));
  print('mirrored-hand A -> ${clf.classify(mirrored)?.label} (expect A)');

  final crossSlot = List<double>.filled(kDim, 0.0);
  crossSlot[otherOff == kLeftOff ? 0 : 1] = 1;
  crossSlot.setRange(otherOff, otherOff + 63, hand);
  print('cross-slot A -> ${clf.classify(crossSlot)?.label} (expect A)');

  // (d) An all-zero vector (no hands) must be "no match".
  final empty = clf.classify(List<double>.filled(kDim, 0.0));
  print('empty vector -> ${empty?.label} (expect null)');

  // (e) The stub landmark source must emit frames, all honestly hand-less,
  // and a frame's feature vector must be the canonical 128 floats.
  final stub = StubLandmarkSource();
  await stub.start();
  final frames = await stub.frames
      .take(3)
      .toList()
      .timeout(const Duration(seconds: 5));
  await stub.dispose();
  print('stub frames: ${frames.length}, all hand-less: '
      '${frames.every((f) => !f.hasHand)}, vector dim: '
      '${frames.first.toFeatureVector().length} (expect 128)');
}
