/// SignVoice — hand-landmark input abstraction.
///
/// All hand tracking enters the app through a single [LandmarkSource], so
/// the camera/ML stack can be swapped without touching the classifier or
/// the UI. A source emits [HandFrame]s; each frame carries the 21 landmarks
/// of the left and/or right hand (either may be null when not detected),
/// in the same normalised image coordinates MediaPipe produces.
library;

import 'dart:async';

import 'classifier.dart';

/// One frame of hand landmarks.
class HandFrame {
  /// 21 landmarks of the signer's left hand, or null if not detected.
  final List<LandmarkPoint>? leftHand;

  /// 21 landmarks of the signer's right hand, or null if not detected.
  final List<LandmarkPoint>? rightHand;

  /// Frame time in milliseconds (any monotonic clock).
  final int timestampMs;

  const HandFrame({this.leftHand, this.rightHand, required this.timestampMs});

  /// True when at least one hand was detected in this frame.
  bool get hasHand => leftHand != null || rightHand != null;

  /// The canonical 128-float feature vector for this frame.
  List<double> toFeatureVector() => makeVector(leftHand, rightHand);
}

/// A source of hand-landmark frames (camera + hand-tracking model).
abstract class LandmarkSource {
  /// Stream of frames; subscribe before calling [start].
  Stream<HandFrame> get frames;

  /// Human-readable description of this source, shown in the UI so it is
  /// always obvious whether real tracking is running.
  String get description;

  Future<void> start();
  Future<void> dispose();
}

/// STUB landmark source — NO real hand tracking.
///
/// This placeholder exists so the app shell, classifier and sentence UI
/// can be built and exercised end-to-end before a MediaPipe Hand
/// Landmarker bridge is wired in. It emits empty frames (no hands) at
/// ~15 fps, so the classifier honestly reports "no match" and the UI sits
/// at "Show a sign…". It NEVER fabricates landmarks or predictions.
///
/// Replace with a MediaPipe-backed implementation of [LandmarkSource];
/// nothing else in the app needs to change.
class StubLandmarkSource implements LandmarkSource {
  final StreamController<HandFrame> _controller =
      StreamController<HandFrame>.broadcast();
  Timer? _timer;
  bool _disposed = false;

  @override
  Stream<HandFrame> get frames => _controller.stream;

  @override
  String get description =>
      'Stub — no hand tracking connected. Predictions stay empty; '
      'this is a placeholder, not a recogniser.';

  @override
  Future<void> start() async {
    _timer ??= Timer.periodic(const Duration(milliseconds: 66), (_) {
      if (_disposed) return;
      _controller.add(
        HandFrame(timestampMs: DateTime.now().millisecondsSinceEpoch),
      );
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _controller.close();
  }
}
