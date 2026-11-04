/// SignVoice — ISL Sign-to-Voice (native app scaffold).
///
/// One Flutter codebase for Android and iOS. This shell mirrors the web
/// prototype (~/workspace/isl_sign_voice/): camera stage, big prediction +
/// confidence, hold-to-add sentence strip with Speak / Space / Backspace /
/// Clear, and a teach-mode entry point.
///
/// The classifier (lib/classifier.dart) is a faithful port of the web
/// prototype's, and the bundled starter model
/// (assets/model/starter_samples.json) is the identical file, so samples
/// stay compatible with the web prototype's teach-mode exports.
///
/// Hand tracking is live: frames come from [MediaPipeLandmarkSource]
/// (camera + MediaPipe Hand Landmarker, Android). If the camera is
/// unavailable or permission is denied, the stage says so plainly
/// instead of pretending to track.
library;

import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';

import 'classifier.dart';
import 'landmark_source.dart';
import 'mediapipe_landmark_source.dart';

void main() {
  runApp(const SignVoiceApp());
}

class SignVoiceApp extends StatelessWidget {
  const SignVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignVoice',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SignClassifier _classifier = SignClassifier();
  final SentenceBuilder _sentence = SentenceBuilder();
  final FlutterTts _tts = FlutterTts();

  // The landmark feed: live MediaPipe hand tracking. (StubLandmarkSource
  // in landmark_source.dart remains for emulator/test use.)
  late final MediaPipeLandmarkSource _landmarkSource;

  late final PredictionSmoother _smoother;
  final Stopwatch _clock = Stopwatch()..start();
  StreamSubscription<HandFrame>? _frameSub;

  Prediction? _prediction;
  String _status = 'Loading starter model…';
  bool _autoSpeak = false;
  bool _modelReady = false;

  @override
  void initState() {
    super.initState();
    _smoother = PredictionSmoother(onCommit: _onSignCommitted);
    _initTts();
    _loadModel();
    _landmarkSource = MediaPipeLandmarkSource(
      onCameraReady: () {
        if (mounted) setState(() {});
      },
    );
    _frameSub = _landmarkSource.frames.listen(_onFrame);
    _landmarkSource.start();
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _landmarkSource.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    // Voice preference mirrors the web prototype: Hindi first, then
    // Indian English, then any English.
    for (final lang in ['hi-IN', 'en-IN', 'en-US']) {
      try {
        final ok = await _tts.setLanguage(lang);
        if (ok == 1) break;
      } catch (_) {
        // Language not available on this device; try the next one.
      }
    }
  }

  Future<void> _loadModel() async {
    try {
      final raw = await rootBundle.loadString(
        'assets/model/starter_samples.json',
      );
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final starterLabels = decoded['labels'] as Map<String, dynamic>?;
      _classifier.rebuildStore(starterLabels: starterLabels);
      if (!mounted) return;
      setState(() {
        _modelReady = true;
        _status =
            'Starter model loaded: ${_classifier.labels.length} ISL '
            'alphabet signs, ${_classifier.sampleCount} samples.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status =
            'Starter model could not be loaded ($e). '
            'Teach mode can still add signs once tracking is connected.';
      });
    }
  }

  void _onFrame(HandFrame frame) {
    if (!_modelReady) return;
    final now = _clock.elapsedMilliseconds;
    final pred = frame.hasHand
        ? _classifier.classify(frame.toFeatureVector())
        : null;
    _smoother.observe(pred, now);
    if (mounted && pred?.label != _prediction?.label) {
      setState(() => _prediction = pred);
    } else {
      _prediction = pred;
    }
  }

  void _onSignCommitted(String label) {
    setState(() => _sentence.append(label));
    if (_autoSpeak && label.length > 1) _speak(_sentence.text);
  }

  Future<void> _speak(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _tts.stop();
    await _tts.speak(t);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final confidence = _prediction?.confidence ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SignVoice — ISL Sign to Voice'),
        actions: [
          IconButton(
            icon: const Icon(Icons.school),
            tooltip: 'Teach mode',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TeachScreen(classifier: _classifier),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- Camera stage (live preview once the camera is ready) ----
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child:
                  _landmarkSource.cameraReady &&
                      _landmarkSource.cameraController != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CameraPreview(_landmarkSource.cameraController!),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _landmarkSource.description,
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(_status, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          // ---- Prediction ----
          Text(
            _prediction?.label ?? '—',
            style: theme.textTheme.displayMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: confidence),
          const SizedBox(height: 4),
          Text(
            _prediction == null
                ? 'Show a sign…'
                : 'Confidence ${(confidence * 100).round()}%',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          // ---- Sentence strip ----
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outline),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _sentence.text.isEmpty
                  ? 'Your sentence appears here…'
                  : _sentence.text,
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.volume_up),
                label: const Text('Speak'),
                onPressed: () => _speak(_sentence.text),
              ),
              OutlinedButton(
                onPressed: () {
                  final pred = _prediction;
                  if (pred != null) _onSignCommitted(pred.label);
                },
                child: const Text('Add sign'),
              ),
              OutlinedButton(
                onPressed: () => setState(_sentence.addSpace),
                child: const Text('Space'),
              ),
              OutlinedButton(
                onPressed: () => setState(_sentence.backspace),
                child: const Text('Backspace'),
              ),
              OutlinedButton(
                onPressed: () => setState(_sentence.clear),
                child: const Text('Clear'),
              ),
            ],
          ),
          SwitchListTile(
            title: const Text('Speak sentence as words are added'),
            value: _autoSpeak,
            onChanged: (v) => setState(() => _autoSpeak = v),
          ),
        ],
      ),
    );
  }
}

/// Teach mode.
///
/// Shows the signs the classifier currently knows, with sample counts —
/// that part is real. Recording new samples is not built yet; the screen
/// says so plainly instead of pretending to record.
class TeachScreen extends StatelessWidget {
  final SignClassifier classifier;

  const TeachScreen({super.key, required this.classifier});

  @override
  Widget build(BuildContext context) {
    final labels = classifier.labels;
    return Scaffold(
      appBar: AppBar(title: const Text('Teach mode')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Teach SignVoice a new sign by recording about 10 samples of '
            'it. Recording new samples is not built yet — the record flow '
            'is the next step after live tracking.',
          ),
          const SizedBox(height: 16),
          Text(
            'Known signs (${labels.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (labels.isEmpty)
            const Text('No signs loaded yet.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final label in labels)
                  Chip(
                    label: Text('$label · ${classifier.sampleCountFor(label)}'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
