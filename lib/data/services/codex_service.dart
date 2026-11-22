/// Community codex (法典) browsing: pack list, pack JSON cache and paged search.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/codex_models.dart';
import 'network_proxy_service.dart';

/// Raised when the codex CDN is unreachable or returns an unexpected payload.
class CodexException implements Exception {
  const CodexException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'CodexException($message)';
}

/// Loads community codex packs from the quicktagcloud CDN.
class CodexService {
  CodexService._()
    : this._raw(
        NetworkProxyService.instance.createClient(NetworkFeature.gallery),
        _defaultDataBase,
      );

  CodexService.forTesting({required http.Client client, String? dataBase})
    : this._raw(client, dataBase ?? _defaultDataBase);

  CodexService._raw(this._client, this._dataBase);

  static const String _defaultDataBase =
      'https://assets.quicktagcloud.com/data/';
  static const String _imageBase = 'https://assets.quicktagcloud.com/images/';
  static const String _defaultPackId = 'nai5_community_pack';
  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'novelai-harness',
    'Accept': 'application/json, text/plain, */*',
  };

  static final CodexService instance = CodexService._();

  final http.Client _client;
  final String _dataBase;

  final Map<String, Map<String, dynamic>> _packs =
      <String, Map<String, dynamic>>{};
  String? _releaseBase;
  List<CodexPack>? _packsList;

  /// All published codexes.
  Future<List<CodexPack>> listPacks() async {
    final cached = _packsList;
    if (cached != null) return cached;
    final base = await _resolveBase();
    final response = await _get('${base}codexes.json');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const CodexException('法典清单格式未知');
    }
    final packs = decoded
        .whereType<Map>()
        .map((item) => CodexPack.fromJson(Map<String, dynamic>.from(item)))
        .where((pack) => pack.id.isNotEmpty)
        .toList(growable: false);
    _packsList = packs;
    return packs;
  }

  /// Search one pack; the pack JSON is downloaded once and cached in memory.
  Future<CodexSearchResult> search({
    String packId = _defaultPackId,
    String query = '',
    String category = '',
    int page = 1,
    int limit = 36,
  }) async {
    final id = packId.trim().isEmpty ? _defaultPackId : packId.trim();
    final data = await _loadPack(id);
    final entries = data['entries'];
    final term = query.trim().toLowerCase();
    final cat = category.trim();
    final filtered = <Map<String, dynamic>>[];
    if (entries is List) {
      for (final raw in entries.whereType<Map>()) {
        final entry = Map<String, dynamic>.from(raw);
        if (cat.isNotEmpty) {
          final rawPath = entry['path'];
          final pathText = rawPath is List
              ? rawPath.join(' / ')
              : '${rawPath ?? ''}';
          if (!pathText.contains(cat)) continue;
        }
        if (term.isNotEmpty) {
          final haystack =
              '${entry['title'] ?? ''} ${entry['tags'] ?? ''} ${entry['serialTitle'] ?? ''}'
                  .toLowerCase();
          if (!haystack.contains(term)) continue;
        }
        filtered.add(entry);
      }
    }
    final size = limit.clamp(6, 60).toInt();
    final safePage = page < 1 ? 1 : page;
    final start = (safePage - 1) * size;
    final end = (start + size).clamp(0, filtered.length).toInt();
    final slice = start >= filtered.length
        ? const <Map<String, dynamic>>[]
        : filtered.sublist(start, end);
    final pages = (filtered.length / size).ceil();
    return CodexSearchResult(
      packId: id,
      title: '${data['title'] ?? '法典'}',
      version: '${data['version'] ?? ''}',
      total: filtered.length,
      page: safePage,
      pages: pages < 1 ? 1 : pages,
      categories: _categoriesOf(data['tree']),
      entries: slice
          .map((entry) => _entryOf(id, entry))
          .toList(growable: false),
    );
  }

  /// Resolve a codex image file to its CDN URL.
  String imageUrl(String packId, String file) {
    final safePack = packId.replaceAll(RegExp(r'[^\w-]'), '');
    return '$_imageBase${Uri.encodeComponent(safePack)}/${Uri.encodeComponent(file)}';
  }

  /// Download a codex image.
  Future<Uint8List> fetchImage(String url) async {
    final response = await _client.get(Uri.parse(url), headers: _headers);
    if (response.statusCode != 200) {
      throw CodexException(
        '法典图片返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return response.bodyBytes;
  }

  Future<String> _resolveBase() async {
    final cached = _releaseBase;
    if (cached != null) return cached;
    final response = await _get('${_dataBase}current.json');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const CodexException('法典索引格式未知');
    final manifest = '${decoded['manifest'] ?? ''}';
    final base = '$_dataBase${manifest.replaceAll(RegExp(r'[^/]+$'), '')}';
    _releaseBase = base;
    return base;
  }

  Future<Map<String, dynamic>> _loadPack(String id) async {
    final cached = _packs[id];
    if (cached != null) return cached;
    final base = await _resolveBase();
    final response = await _get('$base$id.json');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) throw const CodexException('法典内容格式未知');
    final data = Map<String, dynamic>.from(decoded);
    _packs[id] = data;
    return data;
  }

  Future<http.Response> _get(String url) async {
    final http.Response response;
    try {
      response = await _client.get(Uri.parse(url), headers: _headers);
    } on Exception catch (error) {
      throw CodexException('法典不可达：$error');
    }
    if (response.statusCode != 200) {
      throw CodexException(
        '法典返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  List<CodexCategory> _categoriesOf(Object? tree) {
    final out = <CodexCategory>[];
    void walk(Object? nodes, int depth, String prefix) {
      if (nodes is! List) return;
      for (final raw in nodes.whereType<Map>()) {
        final name = '${raw['name'] ?? ''}';
        final path = prefix.isEmpty ? name : '$prefix / $name';
        if (depth < 2) {
          out.add(
            CodexCategory(
              name: name,
              path: path,
              count: (raw['count'] is num) ? (raw['count'] as num).toInt() : 0,
              depth: depth,
            ),
          );
        }
        if (depth < 1) walk(raw['children'], depth + 1, path);
      }
    }

    walk(tree, 0, '');
    return out;
  }

  CodexEntry _entryOf(String packId, Map<String, dynamic> entry) {
    final rawImages = entry['images'];
    final imageName = '${entry['image'] ?? ''}';
    final files = <String>[];
    if (rawImages is List && rawImages.isNotEmpty) {
      for (final raw in rawImages.whereType<Map>()) {
        final name = '${raw['path'] ?? raw['image'] ?? ''}'.trim();
        if (name.isNotEmpty) files.add(name);
      }
    }
    if (files.isEmpty && imageName.isNotEmpty) files.add(imageName);
    return CodexEntry(
      id: '${entry['id'] ?? ''}',
      title: '${entry['title'] ?? ''}',
      tags: '${entry['tags'] ?? ''}',
      negative: '${entry['negative'] ?? ''}',
      rating: '${entry['rating'] ?? ''}',
      note: '${entry['note'] ?? ''}',
      width: entry['imageWidth'] is num
          ? (entry['imageWidth'] as num).toInt()
          : null,
      height: entry['imageHeight'] is num
          ? (entry['imageHeight'] as num).toInt()
          : null,
      imageFiles: List<String>.unmodifiable(files),
    );
  }
}
