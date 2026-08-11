import 'package:flutter/material.dart';
import 'package:voice_command_kit/voice_command_kit.dart';

void main() {
  runApp(const ExampleApp());
}

/// The whole configuration this demo needs: three generic models, one wake
/// word, and a command per phrase you want to act on.
///
/// Note there is nothing about *this* app in here — swapping the app means
/// swapping the ids and the phrases.
final _config = VoicePipelineConfig(
  features: const FeatureModels(
    melSpectrogram: ModelSource.asset('assets/models/melspectrogram.onnx'),
    embedding: ModelSource.asset('assets/models/embedding_model.onnx'),
  ),
  wakeWord: const WakeWordModel(
    id: 'hey_sunny',
    classifier: ModelSource.asset('assets/models/hey_sunny.onnx'),
  ),
  commands: const [
    VoiceCommand(
      id: 'turn_on',
      phrases: ['turn on', 'turn on the lights'],
      classifier: ModelSource.asset('assets/models/turn_on.onnx'),
    ),
    VoiceCommand(
      id: 'turn_off',
      phrases: ['turn off', 'turn off the lights'],
      classifier: ModelSource.asset('assets/models/turn_off.onnx'),
    ),
  ],
);

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  late final VoicePipeline _pipeline;
  final List<String> _log = [];
  bool _lightsOn = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();

    _pipeline = VoicePipeline(
      config: _config,
      logger: _PrintLogger(_append),
      notifier: _AppendingNotifier(_append),
      // Only offer the command that would change something. The package takes
      // this at face value — it has no idea what a light is.
      availableCommands: () => _lightsOn ? ['turn_off'] : ['turn_on'],
      onCommand: _handleCommand,
    );
  }

  Future<bool> _handleCommand(String commandId) async {
    switch (commandId) {
      case 'turn_on':
        setState(() => _lightsOn = true);
        return true;
      case 'turn_off':
        setState(() => _lightsOn = false);
        return true;
      default:
        return false;
    }
  }

  void _append(String message) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, message);
      if (_log.length > 100) _log.removeLast();
    });
  }

  Future<void> _toggleListening() async {
    if (_running) {
      await _pipeline.stop();
    } else {
      await _pipeline.start();
    }
    if (mounted) setState(() => _running = _pipeline.isRunning);
  }

  @override
  void dispose() {
    _pipeline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('voice_command_kit')),
        body: Column(
          children: [
            ListTile(
              leading: Icon(
                _lightsOn ? Icons.lightbulb : Icons.lightbulb_outline,
                color: _lightsOn ? Colors.amber : null,
              ),
              title: Text(_lightsOn ? 'Lights are on' : 'Lights are off'),
              subtitle: const Text('Say "Hey Sunny", then "turn on/off"'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton(
                onPressed: _toggleListening,
                child: Text(_running ? 'Stop listening' : 'Start listening'),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                reverse: false,
                itemCount: _log.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  child: Text(
                    _log[index],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrintLogger implements VoiceLogger {
  const _PrintLogger(this._append);

  final void Function(String) _append;

  @override
  void info(String message, [Map<String, Object?>? data]) =>
      _append('[i] $message${data == null ? '' : ' $data'}');

  @override
  void warn(String message, [Map<String, Object?>? data]) =>
      _append('[!] $message${data == null ? '' : ' $data'}');

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) =>
      _append('[x] $message${error == null ? '' : ' $error'}');
}

class _AppendingNotifier implements VoiceNotifier {
  const _AppendingNotifier(this._append);

  final void Function(String) _append;

  @override
  void notify(VoiceFeedback feedback) => _append('>>> ${feedback.name}');

  @override
  void notifyTranscript(String transcript) => _append('>>> heard "$transcript"');
}
