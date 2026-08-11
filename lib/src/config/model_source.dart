import 'dart:typed_data';

/// Where an ONNX model comes from.
///
/// The package ships no models of its own, so every model in a
/// configuration is described by one of these. Assets and raw bytes are
/// materialised to a file before inference, because the native engine takes
/// paths; [ModelSource.file] is handed straight through.
sealed class ModelSource {
  const ModelSource();

  /// A Flutter asset, e.g. `assets/models/wake_word.onnx`.
  ///
  /// Pass [package] when the asset ships inside another package rather than
  /// the application.
  const factory ModelSource.asset(String path, {String? package}) =
      AssetModelSource;

  /// A model already on disk. Used as-is — nothing is copied.
  const factory ModelSource.file(String path) = FileModelSource;

  /// Model bytes held in memory, e.g. one just downloaded.
  ///
  /// [name] is the file name the bytes are written under, and identifies them
  /// in the cache: two different models must not share one.
  const factory ModelSource.bytes(Uint8List bytes, {required String name}) =
      BytesModelSource;

  /// Stable identity for caching. Two sources with the same key are treated as
  /// the same model file.
  String get cacheKey;
}

final class AssetModelSource extends ModelSource {
  const AssetModelSource(this.path, {this.package});

  final String path;
  final String? package;

  /// The key a Flutter asset is loaded by: assets from a package are namespaced
  /// under `packages/<name>/`.
  String get bundleKey => package == null ? path : 'packages/$package/$path';

  @override
  String get cacheKey => bundleKey.split('/').last;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssetModelSource &&
          other.path == path &&
          other.package == package;

  @override
  int get hashCode => Object.hash(path, package);
}

final class FileModelSource extends ModelSource {
  const FileModelSource(this.path);

  final String path;

  @override
  String get cacheKey => path;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FileModelSource && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

final class BytesModelSource extends ModelSource {
  const BytesModelSource(this.bytes, {required this.name});

  final Uint8List bytes;
  final String name;

  @override
  String get cacheKey => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BytesModelSource && other.name == name && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(name, bytes);
}
