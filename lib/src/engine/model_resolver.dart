import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../config/model_source.dart';

/// Turns [ModelSource]s into on-disk paths, which is all the native engine
/// accepts.
///
/// Assets and byte buffers are written into the application support directory
/// and reused across launches; a file source is passed through untouched.
final class ModelResolver {
  ModelResolver({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final Map<String, String> _resolved = {};

  /// Resolves [source] to a path, or throws a [StateError] naming exactly
  /// which model failed and why — a missing [ModelSource.file] path, or an
  /// asset not declared in `pubspec.yaml`. [label] identifies the model in
  /// that message (e.g. a [WakeWordModel.id]); pass it whenever the caller
  /// knows what it is resolving, so a broken config fails with something more
  /// useful than a bare file path.
  Future<String> resolve(ModelSource source, {String? label}) async {
    if (source is FileModelSource) {
      if (!await File(source.path).exists()) {
        throw StateError(
          '${_prefix(label)}model file not found at "${source.path}". '
          'ModelSource.file() expects a path that already exists — nothing '
          'copies or downloads it.',
        );
      }
      return source.path;
    }

    final cached = _resolved[source.cacheKey];
    if (cached != null) return cached;

    final path = switch (source) {
      AssetModelSource() => await _writeIfChanged(
        source.cacheKey,
        await _loadAssetBytes(source, label),
      ),
      BytesModelSource() => await _writeIfChanged(source.cacheKey, source.bytes),
      // Handled above; repeated for exhaustiveness.
      FileModelSource() => source.path,
    };

    _resolved[source.cacheKey] = path;
    return path;
  }

  Future<Uint8List> _loadAssetBytes(AssetModelSource source, String? label) async {
    try {
      return (await _bundle.load(source.bundleKey)).buffer.asUint8List();
    } on Object catch (error) {
      throw StateError(
        '${_prefix(label)}model asset "${source.bundleKey}" failed to load: '
        '$error. Check it is declared under flutter > assets in pubspec.yaml.',
      );
    }
  }

  static String _prefix(String? label) => label == null ? '' : '"$label" ';

  Future<String> _writeIfChanged(String fileName, Uint8List bytes) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');

    // Length is a deliberately cheap stand-in for a content hash: models are
    // megabytes, are only replaced by a new build of the app, and a same-length
    // replacement of a different model is not a case worth paying a hash per
    // launch for.
    if (await file.exists() && await file.length() == bytes.length) {
      return file.path;
    }

    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
