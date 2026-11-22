import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/danbooru_models.dart';
import 'network_proxy_service.dart';

/// Danbooru 图库搜索/下载服务。
///
/// 只依赖公开的 `posts.json` 与 CDN 文件地址；代理由全局
/// [HttpOverrides] 统一处理，因此这里使用普通 [http.Client]。
class DanbooruException implements Exception {
  const DanbooruException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class DanbooruGalleryService {
  DanbooruGalleryService._()
    : this._raw(
        NetworkProxyService.instance.createClient(NetworkFeature.gallery),
        _defaultBaseUrl,
      );

  DanbooruGalleryService.forTesting({
    required http.Client client,
    String? baseUrl,
  }) : this._raw(client, baseUrl ?? _defaultBaseUrl);

  DanbooruGalleryService._raw(this._client, this._baseUrl);

  static const String _defaultBaseUrl = 'https://danbooru.donmai.us';
  static const int _pageSize = 40;
  static const int _maxImageBytes = 32 * 1024 * 1024;
  static const Duration _searchTimeout = Duration(seconds: 25);
  static const Duration _imageTimeout = Duration(seconds: 90);

  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'NovelAI-Harness/0.5.3 (Flutter gallery)',
    'Accept': 'application/json,image/*,*/*',
    'Referer': 'https://danbooru.donmai.us/',
  };

  static const Set<String> _imageExtensions = <String>{
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
  };

  static final DanbooruGalleryService instance = DanbooruGalleryService._();

  final http.Client _client;
  final String _baseUrl;

  /// 搜索帖子。未显式指定 `rating:` 时自动补 `rating:general`，
  /// 避免默认打开画廊就出现 R-18；需要时把 `rating:explicit` 写进查询即可。
  Future<List<DanbooruPost>> search(
    String query, {
    int page = 1,
    int limit = _pageSize,
    String rating = 'general',
  }) async {
    final raw = query.trim();
    final effectiveRating =
        const {'general', 'questionable', 'explicit', 'all'}.contains(rating)
        ? rating
        : 'general';
    final hasRating = RegExp(r'(^|\s)rating:').hasMatch(raw);
    final hasOrder = RegExp(r'(^|\s)order:').hasMatch(raw);
    final parts = <String>[
      raw,
      if (!hasOrder) 'order:rank',
      if (!hasRating && effectiveRating != 'all') 'rating:$effectiveRating',
    ];
    var tags = parts.where((part) => part.isNotEmpty).join(' ');
    if (tags.isEmpty) tags = 'rating:general';
    final uri = Uri.parse('$_baseUrl/posts.json').replace(
      queryParameters: <String, String>{
        'tags': tags,
        'page': '${page < 1 ? 1 : page}',
        'limit': '${limit.clamp(1, 200)}',
      },
    );
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: _headers)
          .timeout(_searchTimeout);
    } on TimeoutException {
      throw const DanbooruException('Danbooru 请求超时，请检查网络或代理设置');
    } on Exception catch (error) {
      throw DanbooruException('Danbooru 不可达：$error');
    }
    if (response.statusCode == 429) {
      throw const DanbooruException('Danbooru 请求过于频繁，请稍后再试', statusCode: 429);
    }
    if (response.statusCode != 200) {
      throw DanbooruException(
        'Danbooru 返回 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const DanbooruException('Danbooru 返回格式异常');
    }
    final posts = <DanbooruPost>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final post = DanbooruPost.fromJson(Map<String, dynamic>.from(item));
      if (post.id <= 0 || post.thumbnailUrl == null) continue;
      if (post.fileExt.isNotEmpty && !_imageExtensions.contains(post.fileExt)) {
        continue;
      }
      posts.add(post);
    }
    return posts;
  }

  /// 下载原图；没有原图时退回大图/缩略图。
  Future<Uint8List> fetchImageBytes(DanbooruPost post) async {
    final url = post.bestImageUrl;
    if (url == null) {
      throw const DanbooruException('该帖子没有可下载的图片地址');
    }
    return fetchUrlBytes(url);
  }

  /// 下载缩略图，供画廊避免绕过功能级代理设置。
  Future<Uint8List> fetchThumbnailBytes(DanbooruPost post) async {
    final url = post.thumbnailUrl;
    if (url == null) {
      throw const DanbooruException('该帖子没有可显示的缩略图');
    }
    return fetchUrlBytes(url);
  }

  Future<Uint8List> fetchUrlBytes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const DanbooruException('图片地址不合法');
    }
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: _headers)
          .timeout(_imageTimeout);
    } on TimeoutException {
      throw const DanbooruException('图片下载超时');
    } on Exception catch (error) {
      throw DanbooruException('图片下载失败：$error');
    }
    if (response.statusCode != 200) {
      throw DanbooruException(
        '图片下载 HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) {
      throw const DanbooruException('图片内容为空');
    }
    if (bytes.length > _maxImageBytes) {
      throw const DanbooruException('图片超过 32MB，已拒绝下载');
    }
    return bytes;
  }

  void dispose() => _client.close();
}
