import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../models/nai_generation_params.dart';

enum ReferenceLibraryKind { precise, vibe }

class ReferenceLibraryEntry {
  final String id;
  final String fileName;
  final ReferenceLibraryKind kind;
  final String name;
  final Uint8List? bytes;
  final Uint8List thumbnailBytes;
  final NaiPreciseRefType preciseType;
  final double strength;
  final double fidelity;
  final double informationExtracted;
  final bool preferSameOutfit;
  final DateTime createdAt;

  ReferenceLibraryEntry({
    required this.id,
    String? fileName,
    required this.kind,
    required this.name,
    this.bytes,
    Uint8List? thumbnailBytes,
    this.preciseType = NaiPreciseRefType.characterAndStyle,
    this.strength = 1.0,
    this.fidelity = 1.0,
    this.informationExtracted = 1.0,
    this.preferSameOutfit = false,
    required this.createdAt,
  }) : fileName = fileName ?? '$id.png',
       thumbnailBytes = thumbnailBytes ?? bytes ?? Uint8List(0);

  ReferenceLibraryEntry copyWith({
    String? name,
    NaiPreciseRefType? preciseType,
    double? strength,
    double? fidelity,
    double? informationExtracted,
    bool? preferSameOutfit,
  }) => ReferenceLibraryEntry(
    id: id,
    fileName: fileName,
    kind: kind,
    name: name ?? this.name,
    bytes: bytes,
    thumbnailBytes: thumbnailBytes,
    preciseType: preciseType ?? this.preciseType,
    strength: strength ?? this.strength,
    fidelity: fidelity ?? this.fidelity,
    informationExtracted:
        informationExtracted ?? this.informationExtracted,
    preferSameOutfit: preferSameOutfit ?? this.preferSameOutfit,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'file': fileName,
    'thumb': '${id}_thumb.png',
    'kind': kind.name,
    'name': name,
    'preciseType': preciseType.name,
    'strength': strength,
    'fidelity': fidelity,
    'informationExtracted': informationExtracted,
    'preferSameOutfit': preferSameOutfit,
    'createdAt': createdAt.toIso8601String(),
  };
}

class ReferenceLibraryService {
  ReferenceLibraryService._();
  static final ReferenceLibraryService instance = ReferenceLibraryService._();
  static const int maxEntries = 100;
  static const int maxImageBytes = 20 * 1024 * 1024;
  static const int maxTotalBytes = 512 * 1024 * 1024;
  static int _idSeq = 0;
  static Directory? _testDirectory;
  bool _cleanedTemp = false;

  /// 测试注入存储目录。
  static void setStorageDirectoryForTesting(Directory? directory) {
    _testDirectory = directory;
  }
  Future<void> _queue = Future.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<Directory> _dir() async {
    final test = _testDirectory;
    if (test != null) {
      await test.create(recursive: true);
      return test;
    }
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'reference_library'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<ReferenceLibraryEntry>> load() => _serialized(_loadUnlocked);

  Future<List<ReferenceLibraryEntry>> _loadUnlocked() async {
    try {
      final dir = await _dir();
      if (!_cleanedTemp) {
        await _cleanupTempFiles(dir);
        _cleanedTemp = true;
      }
      final manifest = File(p.join(dir.path, 'manifest.json'));
      if (!await manifest.exists()) return const [];
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! List) return const [];
      final result = <ReferenceLibraryEntry>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final file = '${item['file'] ?? ''}';
        final thumb = '${item['thumb'] ?? file}';
        if (file.isEmpty ||
            p.basename(file) != file ||
            p.basename(thumb) != thumb) {
          continue;
        }
        try {
          Uint8List bytes;
          try {
            bytes = await File(p.join(dir.path, thumb)).readAsBytes();
          } on Object {
            // Legacy entries may not have a thumbnail yet.
            bytes = await File(p.join(dir.path, file)).readAsBytes();
          }
          if (bytes.isEmpty) continue;
          result.add(
            ReferenceLibraryEntry(
              id: '${item['id'] ?? ''}',
              fileName: file,
              kind: '${item['kind']}' == 'vibe'
                  ? ReferenceLibraryKind.vibe
                  : ReferenceLibraryKind.precise,
              name: '${item['name'] ?? 'reference'}',
              bytes: null,
              thumbnailBytes: bytes,
              preciseType: NaiPreciseRefType.values.firstWhere(
                (value) => value.name == '${item['preciseType']}',
                orElse: () => NaiPreciseRefType.characterAndStyle,
              ),
              strength: ((item['strength'] as num?)?.toDouble() ?? 1.0)
                  .clamp(
                    0.0,
                    '${item['kind']}' == 'vibe' ? 1.0 : 5.0,
                  ),
              fidelity: ((item['fidelity'] as num?)?.toDouble() ?? 1.0).clamp(
                0.0,
                1.0,
              ),
              informationExtracted:
                  ((item['informationExtracted'] as num?)?.toDouble() ?? 1.0)
                      .clamp(0.01, 1.0),
              preferSameOutfit: item['preferSameOutfit'] == true,
              createdAt:
                  DateTime.tryParse('${item['createdAt']}') ?? DateTime.now(),
            ),
          );
        } on Object {
          continue;
        }
      }
      result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return result;
    } on Object {
      return const [];
    }
  }

  Future<ReferenceLibraryEntry?> add({
    required ReferenceLibraryKind kind,
    required String name,
    required Uint8List bytes,
    NaiPreciseRefType preciseType = NaiPreciseRefType.characterAndStyle,
    double strength = 1.0,
    double fidelity = 1.0,
    double informationExtracted = 1.0,
    bool preferSameOutfit = false,
  }) => _serialized(() async {
    if (bytes.isEmpty || bytes.length > maxImageBytes) return null;
    try {
      final dir = await _dir();
      final existing = await _loadUnlocked();
      if (existing.length >= maxEntries) return null;
      var totalBytes = 0;
      for (final item in existing) {
        try {
          totalBytes += await File(p.join(dir.path, item.fileName)).length();
        } on Object {
          // Missing file does not block adding new entries.
        }
      }
      if (totalBytes + bytes.length > maxTotalBytes) return null;
      final id =
          '${kind.name}_${DateTime.now().microsecondsSinceEpoch}_${_idSeq++}';
      final file = '$id.png';
      final thumbFile = '${id}_thumb.png';
      final imageFile = File(p.join(dir.path, file));
      final thumb = await _makeThumbnailAsync(bytes);
      await imageFile.writeAsBytes(bytes, flush: true);
      await File(p.join(dir.path, thumbFile)).writeAsBytes(thumb, flush: true);
      final safeStrength = strength.clamp(
        0.0,
        kind == ReferenceLibraryKind.precise ? 5.0 : 1.0,
      );
      final entry = ReferenceLibraryEntry(
        id: id,
        fileName: file,
        kind: kind,
        name: name.trim().isEmpty ? id : name.trim(),
        bytes: bytes,
        thumbnailBytes: thumb,
        preciseType: preciseType,
        strength: safeStrength,
        fidelity: fidelity.clamp(0.0, 1.0),
        informationExtracted: informationExtracted.clamp(0.01, 1.0),
        preferSameOutfit: preferSameOutfit,
        createdAt: DateTime.now(),
      );
      try {
        await _writeManifest(dir, [entry, ...existing]);
      } on Object {
        try {
          await imageFile.delete();
          final thumbPath = File(p.join(dir.path, '${id}_thumb.png'));
          if (await thumbPath.exists()) await thumbPath.delete();
        } on Object {
          // best-effort rollback
        }
        return null;
      }
      return entry;
    } on Object {
      return null;
    }
  });

  Future<bool> update(ReferenceLibraryEntry entry) => _serialized(() async {
    try {
      final dir = await _dir();
      final existing = await _loadUnlocked();
      final index = existing.indexWhere((item) => item.id == entry.id);
      if (index == -1) return false;
      existing[index] = entry;
      await _writeManifest(dir, existing);
      return true;
    } on Object {
      return false;
    }
  });

  Future<void> remove(ReferenceLibraryEntry entry) => _serialized(() async {
    try {
      final dir = await _dir();
      final existing = await _loadUnlocked();
      final kept = existing.where((item) => item.id != entry.id).toList();
      final file = File(p.join(dir.path, entry.fileName));
      final thumb = File(p.join(dir.path, '${entry.id}_thumb.png'));
      final trashFile = File('${file.path}.deleting');
      final trashThumb = File('${thumb.path}.deleting');
      var moved = false;
      try {
        if (await file.exists()) {
          await file.rename(trashFile.path);
          moved = true;
        }
        if (await thumb.exists()) await thumb.rename(trashThumb.path);
        await _writeManifest(dir, kept);
        if (await trashFile.exists()) await trashFile.delete();
        if (await trashThumb.exists()) await trashThumb.delete();
      } on Object {
        if (moved && await trashFile.exists()) {
          await trashFile.rename(file.path);
        }
        if (await trashThumb.exists()) await thumb.rename(thumb.path);
        rethrow;
      }
    } on Object {
      // best-effort
    }
  });

  Future<Uint8List?> loadFull(ReferenceLibraryEntry entry) async {
    try {
      final dir = await _dir();
      if (p.basename(entry.fileName) != entry.fileName) return null;
      final bytes = await File(p.join(dir.path, entry.fileName)).readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on Object {
      return null;
    }
  }

  Future<Uint8List> _makeThumbnailAsync(Uint8List bytes) async {
    try {
      return await Isolate.run(() => _makeThumbnailSync(bytes));
    } on Object {
      return _makeThumbnailSync(bytes);
    }
  }

  Future<void> _cleanupTempFiles(Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.deleting')) {
          try {
            await entity.delete();
          } on Object {
            // best-effort
          }
        }
      }
    } on Object {
      // best-effort
    }
  }

  Future<void> _writeManifest(
    Directory dir,
    List<ReferenceLibraryEntry> entries,
  ) async {
    final manifest = File(p.join(dir.path, 'manifest.json'));
    final temp = File('${manifest.path}.tmp');
    await temp.writeAsString(
      jsonEncode([for (final item in entries) item.toJson()]),
      flush: true,
    );
    await temp.rename(manifest.path);
  }
}

Uint8List _makeThumbnailSync(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final resized = img.copyResize(
      decoded,
      width: decoded.width > decoded.height ? 320 : null,
      height: decoded.height >= decoded.width ? 320 : null,
    );
    return Uint8List.fromList(img.encodePng(resized));
  } on Object {
    return bytes;
  }
}
