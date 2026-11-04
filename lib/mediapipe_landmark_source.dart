/// SignVoice — live hand-tracking source (MediaPipe Hand Landmarker).
///
/// Camera + MediaPipe bridge implementing [LandmarkSource]: the camera
/// plugin streams YUV frames, the hand_landmarker plugin runs MediaPipe's
/// Hand Landmarker on a background thread and emits [Hand] results, and
/// this class converts them into [HandFrame]s the classifier already
/// understands. Nothing else in the app changes when this source is used.
///
/// Android-only: hand_landmarker 3.1.0 is Android-only, and this app is
/// Android-first by decision. If the camera is unavailable or permission
/// is denied, [start] does not throw — it records the error, and the UI
/// shows it plainly instead of pretending tracking works.
///
/// Handedness note: this plugin version exposes landmarks but not
/// MediaPipe's handedness label, so two-hand slots are assigned by wrist
/// x-position (best effort). This is safe here because the classifier
/// is alignment-aware: it tries same-slot, cross-slot and mirrored
/// matches, so a swapped or mirrored assignment still classifies. One
/// hand always goes to the right-hand slot; the starter model is
/// single-hand, so that path is exact.
library;

import 'dart:async';

import 'package:camera/camera.dart';
import 'package:hand_landmarker/hand_landmarker.dart';

import 'classifier.dart';
import 'landmark_source.dart';

class MediaPipeLandmarkSource implements LandmarkSource {
  final StreamController<HandFrame> _controller =
      StreamController<HandFrame>.broadcast();
  CameraController? _cameraController;
  HandLandmarkerPlugin? _plugin;
  StreamSubscription<List<Hand>>? _landmarkSub;
  bool _disposed = false;
  String? _error;

  /// Called once the camera preview is ready (or once startup has
  /// failed), so the UI can rebuild and show the preview or the error.
  final void Function()? onCameraReady;

  MediaPipeLandmarkSource({this.onCameraReady});

  /// The live camera controller, once initialised; null before that.
  CameraController? get cameraController => _cameraController;

  /// True once the camera preview can be shown.
  bool get cameraReady => _cameraController?.value.isInitialized ?? false;

  /// Last startup error, if any (permission denied, no camera, ...).
  String? get error => _error;

  @override
  Stream<HandFrame> get frames => _controller.stream;

  @override
  String get description => _error != null
      ? 'Live tracking failed: $_error'
      : 'MediaPipe Hand Landmarker — live camera tracking.';

  @override
  Future<void> start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw StateError('No camera found on this device.');
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _cameraController = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      _plugin = HandLandmarkerPlugin.create(
        numHands: 2,
        minHandDetectionConfidence: 0.7,
        // CPU is the safe default; switch to HandLandmarkerDelegate.gpu
        // on devices where the GPU delegate is known to work.
        delegate: HandLandmarkerDelegate.cpu,
      );
      _landmarkSub = _plugin!.landmarkStream.listen(_onHands);
      await _cameraController!.startImageStream(_onCameraImage);
      onCameraReady?.call();
    } catch (e) {
      _error = e.toString();
      onCameraReady?.call();
    }
  }

  void _onCameraImage(CameraImage image) {
    final controller = _cameraController;
    final plugin = _plugin;
    if (_disposed || controller == null || plugin == null) return;
    try {
      // Fire-and-forget by design; a bad frame must never break the UI.
      plugin.processFrame(image, controller.description.sensorOrientation);
    } catch (_) {}
  }

  void _onHands(List<Hand> hands) {
    if (_disposed) return;

    List<LandmarkPoint>? toPoints(Hand hand) {
      if (hand.landmarks.length != 21) return null;
      return [for (final lm in hand.landmarks) LandmarkPoint(lm.x, lm.y, lm.z)];
    }

    List<LandmarkPoint>? left;
    List<LandmarkPoint>? right;
    if (hands.length == 1) {
      right = toPoints(hands[0]);
    } else if (hands.length >= 2) {
      // Best-effort slot assignment by wrist x-position (see note above).
      final ordered = [...hands]
        ..sort((a, b) => a.landmarks[0].x.compareTo(b.landmarks[0].x));
      left = toPoints(ordered[0]);
      right = toPoints(ordered[1]);
    }
    _controller.add(
      HandFrame(
        leftHand: left,
        rightHand: right,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _landmarkSub?.cancel();
    try {
      await _cameraController?.stopImageStream();
    } catch (_) {}
    await _cameraController?.dispose();
    _plugin?.dispose();
    await _controller.close();
  }
}
