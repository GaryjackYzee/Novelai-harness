import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/nai_generation_params.dart';

/// Persists binary reference images as individual files plus a small manifest.
class StudioReferenceStore {
  StudioReferenceStore._();

  static final StudioReferenceStore instance = StudioReferenceStore._();
  String? _lastSignature;

  /// Last persistence error, for diagnostics.
  Object? lastError;

  Future<Directory> _dir() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'studio_reference_images'));
    await dir.create(recursive: true);
    return dir;
  }

  String _signature(NaiGenerationParams params) {
    String hash(Uint8List bytes) =>
        sha256.convert(bytes).toString().substring(0, 16);
    final parts = <String>[
      params.img2imgBytes == null ? '0' : hash(params.img2imgBytes!),
      for (final item in params.referenceImages)
        '${hash(item.bytes)}:${item.strength}:${item.informationExtracted}',
      for (final item in params.preciseReferences)
        '${hash(item.bytes)}:${item.type.name}:${item.strength}:${item.fidelity}:${item.preferSameOutfit}:${item.enabled}',
    ];
    return parts.join('|');
  }

  Future<void> save(NaiGenerationParams params) async {
    final signature = _signature(params);
    if (signature == _lastSignature) return;
    try {
      await _save(params, signature);
      lastError = null;
    } on Object catch (error) {
      lastError = error;
      debugPrint('参考图缓存保存失败: $error');
    }
  }

  String _hash(Uint8List bytes) =>
      sha256.convert(bytes).toString().substring(0, 16);

  Future<void> _save(NaiGenerationParams params, String signature) async {
    final dir = await _dir();
    final manifest = <String, Object?>{
      'version': 2,
      'img2img': null,
      'vibe': <Object?>[],
      'precise': <Object?>[],
    };
    final used = <String>{};
    Future<String> write(String name, Uint8List bytes) async {
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes, flush: true);
      used.add(name);
      return name;
    }

    if (params.img2imgBytes != null) {
      manifest['img2img'] = await write('img2img.bin', params.img2imgBytes!);
    }
    final vibe = <Object?>[];
    for (var i = 0; i < params.referenceImages.length; i += 1) {
      final item = params.referenceImages[i];
      vibe.add({
        'file': await write('vibe_$i.bin', item.bytes),
        'sha256': _hash(item.bytes),
        'strength': item.strength,
        'informationExtracted': item.informationExtracted,
      });
    }
    manifest['vibe'] = vibe;
    final precise = <Object?>[];
    for (var i = 0; i < params.preciseReferences.length; i += 1) {
      final item = params.preciseReferences[i];
      precise.add({
        'file': await write('precise_$i.bin', item.bytes),
        'sha256': _hash(item.bytes),
        'type': item.type.name,
        'strength': item.strength,
        'fidelity': item.fidelity,
        'preferSameOutfit': item.preferSameOutfit,
        'enabled': item.enabled,
      });
    }
    manifest['precise'] = precise;

    final target = File(p.join(dir.path, 'manifest.json'));
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(manifest), flush: true);
    await temp.rename(target.path);
    _lastSignature = signature;

    // Remove files from older layouts or removed references.
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == 'manifest.json' || used.contains(name)) continue;
      if (name.endsWith('.bin') || name.endsWith('.tmp')) {
        try {
          await entity.delete();
        } on Object {
          // best-effort cleanup
        }
      }
    }
  }

  Future<NaiGenerationParams> restore(NaiGenerationParams params) async {
    try {
      final dir = await _dir();
      final manifestFile = File(p.join(dir.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        return await _restoreLegacy(params);
      }
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) return params;
      var invalid = false;
      Uint8List? read(Object? entry) {
        if (entry is! Map) return null;
        final file = '${entry['file'] ?? ''}';
        if (file.isEmpty || p.basename(file) != file) return null;
        try {
          final bytes = File(p.join(dir.path, file)).readAsBytesSync();
          if (bytes.isEmpty) invalid = true;
          final expected = '${entry['sha256'] ?? ''}';
          if (expected.isNotEmpty &&
              sha256.convert(bytes).toString() != expected) {
            invalid = true;
            return null;
          }
          return bytes.isEmpty ? null : bytes;
        } on Object {
          invalid = true;
          return null;
        }
      }

      final img2imgEntry = decoded['img2img'];
      final img2img = img2imgEntry is String
          ? read({'file': img2imgEntry})
          : read(img2imgEntry);
      final vibe = <NaiReferenceImage>[];
      final rawVibe = decoded['vibe'];
      if (rawVibe is List) {
        for (final item in rawVibe) {
          final bytes = read(item);
          if (bytes == null || item is! Map) continue;
          vibe.add(
            NaiReferenceImage(
              bytes: bytes,
              strength: (item['strength'] as num?)?.toDouble() ?? 0.6,
              informationExtracted:
                  (item['informationExtracted'] as num?)?.toDouble() ?? 1.0,
            ),
          );
        }
      }
      final precise = <NaiPreciseReference>[];
      final rawPrecise = decoded['precise'];
      if (rawPrecise is List) {
        for (final item in rawPrecise) {
          final bytes = read(item);
          if (bytes == null || item is! Map) continue;
          final typeName = '${item['type'] ?? 'characterAndStyle'}';
          final type = NaiPreciseRefType.values.firstWhere(
            (value) => value.name == typeName,
            orElse: () => NaiPreciseRefType.characterAndStyle,
          );
          precise.add(
            NaiPreciseReference(
              bytes: bytes,
              type: type,
              strength: (item['strength'] as num?)?.toDouble() ?? 1.0,
              fidelity: (item['fidelity'] as num?)?.toDouble() ?? 1.0,
              preferSameOutfit: item['preferSameOutfit'] == true,
              enabled: item['enabled'] != false,
            ),
          );
        }
      }
      if (invalid) return params;
      final restored = params.copyWith(
        img2imgBytes: img2img,
        clearImg2img: img2img == null,
        referenceImages: vibe,
        preciseReferences: precise,
        clearPreciseReferences: precise.isEmpty,
      );
      _lastSignature = _signature(restored);
      return restored;
    } on Object catch (error) {
      lastError = error;
      debugPrint('参考图缓存读取失败: $error');
      return params;
    }
  }

  Future<NaiGenerationParams> _restoreLegacy(NaiGenerationParams params) async {
    try {
      final root = await getApplicationSupportDirectory();
      final file = File(p.join(root.path, 'studio_reference_images.json'));
      if (!await file.exists()) return params;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return params;
      Uint8List? decode(Object? value) {
        if (value is! String || value.isEmpty) return null;
        try {
          return base64Decode(value);
        } on Object {
          return null;
        }
      }

      final img2img = decode(decoded['img2img']);
      final vibe = <NaiReferenceImage>[];
      final rawVibe = decoded['vibe'];
      if (rawVibe is List) {
        for (final item in rawVibe) {
          if (item is! Map) continue;
          final bytes = decode(item['data']);
          if (bytes == null) continue;
          vibe.add(
            NaiReferenceImage(
              bytes: bytes,
              strength: (item['strength'] as num?)?.toDouble() ?? 0.6,
              informationExtracted:
                  (item['informationExtracted'] as num?)?.toDouble() ?? 1.0,
            ),
          );
        }
      }
      final precise = <NaiPreciseReference>[];
      final rawPrecise = decoded['precise'];
      if (rawPrecise is List) {
        for (final item in rawPrecise) {
          if (item is! Map) continue;
          final bytes = decode(item['data']);
          if (bytes == null) continue;
          final typeName = '${item['type'] ?? 'characterAndStyle'}';
          final type = NaiPreciseRefType.values.firstWhere(
            (value) => value.name == typeName,
            orElse: () => NaiPreciseRefType.characterAndStyle,
          );
          precise.add(
            NaiPreciseReference(
              bytes: bytes,
              type: type,
              strength: (item['strength'] as num?)?.toDouble() ?? 1.0,
              fidelity: (item['fidelity'] as num?)?.toDouble() ?? 1.0,
              preferSameOutfit: item['preferSameOutfit'] == true,
              enabled: item['enabled'] != false,
            ),
          );
        }
      }
      if (img2img == null && vibe.isEmpty && precise.isEmpty) return params;
      return params.copyWith(
        img2imgBytes: img2img,
        clearImg2img: img2img == null,
        referenceImages: vibe,
        preciseReferences: precise,
        clearPreciseReferences: precise.isEmpty,
      );
    } on Object {
      return params;
    }
  }
}
