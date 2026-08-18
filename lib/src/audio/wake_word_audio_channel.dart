import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// The Dart half of the platform audio contract every plugin in this package
/// implements identically.
final class WakeWordAudioChannel {
  WakeWordAudioChannel._();

  static const MethodChannel _methodChannel = MethodChannel(
    'voice_command_kit/audio',
  );
  static const EventChannel _pcmChannel = EventChannel('voice_command_kit/pcm');
  static const EventChannel _deviceEventChannel = EventChannel(
    'voice_command_kit/device_events',
  );

  /// Platforms this package ships a capture plugin for.
  static bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  /// 16 kHz mono Int16 PCM, as captured.
  static Stream<Int16List> pcmStream() {
    if (!isSupported) {
      return const Stream<Int16List>.empty();
    }

    return _pcmChannel.receiveBroadcastStream().map((dynamic event) {
      final bytes = Uint8List.fromList(event as Uint8List);
      return bytes.buffer.asInt16List();
    });
  }

  /// Emits `"defaultInputChanged"` whenever the microphone being captured from
  /// changes — a device switched, was plugged in or unplugged, or the user
  /// picked a different input in system settings.
  ///
  /// The native side has already stopped its capture engine by the time an
  /// event arrives, so the payload carries no detail: there is nothing for the
  /// listener to decide beyond starting again.
  ///
  /// Only the macOS plugin implements this channel today, so listening is
  /// guarded to macOS. `EventChannel.receiveBroadcastStream()` sends an
  /// internal `listen` call to activate the stream; when no plugin answers
  /// it, Flutter routes that specific failure through `FlutterError.reportError`
  /// — not this stream's `onError` — so callers cannot catch it by checking
  /// for `MissingPluginException` the way they can for a normal stream error.
  /// A platform gains the behaviour by adding its native side *and* being
  /// added to the check below.
  static Stream<String> deviceEventStream() {
    if (!Platform.isMacOS) {
      return const Stream<String>.empty();
    }

    return _deviceEventChannel.receiveBroadcastStream().map(
      (dynamic event) => event as String,
    );
  }

  /// Returns whether the microphone may be used, prompting the user if that
  /// question has not been answered yet.
  static Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final result = await _methodChannel.invokeMethod<bool>(
      'checkOrRequestPermission',
    );
    return result ?? false;
  }

  static Future<void> startListening() async {
    if (!isSupported) return;
    await _methodChannel.invokeMethod<void>('startListening');
  }

  static Future<void> stopListening() async {
    if (!isSupported) return;
    await _methodChannel.invokeMethod<void>('stopListening');
  }

  static Future<bool> isListening() async {
    if (!isSupported) return false;
    try {
      final result = await _methodChannel.invokeMethod<bool>('isListening');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
