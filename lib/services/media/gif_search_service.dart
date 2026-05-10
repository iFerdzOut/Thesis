import 'dart:convert';

import 'package:http/http.dart' as http;

class GifResult {
  const GifResult({
    required this.id,
    required this.title,
    required this.previewUrl,
    required this.gifUrl,
  });

  final String id;
  final String title;
  final String previewUrl;
  final String gifUrl;
}

class GifSearchService {
  GifSearchService({http.Client? client}) : _client = client ?? http.Client();

  static const String giphyApiKey = String.fromEnvironment(
    'GIPHY_API_KEY',
    defaultValue: 'xoYuykVJgW1MxPELViwM9E0JqPhktMu2',
  );

  final http.Client _client;

  bool get isConfigured => giphyApiKey.trim().isNotEmpty;

  Future<List<GifResult>> fetch({
    required String query,
    int limit = 24,
  }) async {
    if (!isConfigured) return const <GifResult>[];

    final trimmed = query.trim();
    final path = trimmed.isEmpty ? '/v1/gifs/trending' : '/v1/gifs/search';
    final uri = Uri.https('api.giphy.com', path, {
      'api_key': giphyApiKey,
      'limit': limit.toString(),
      'rating': 'pg-13',
      'lang': 'en',
      if (trimmed.isNotEmpty) 'q': trimmed,
    });

    final response = await _client.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('GIPHY request failed (${response.statusCode}).');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final results = decoded['data'] as List<dynamic>? ?? const <dynamic>[];
    return results
        .map((item) => _parseGiphyResult(item))
        .whereType<GifResult>()
        .toList(growable: false);
  }

  GifResult? _parseGiphyResult(dynamic raw) {
    if (raw is! Map) return null;
    final data = Map<String, dynamic>.from(raw);
    final images = data['images'];
    if (images is! Map) return null;
    final imageMap = Map<String, dynamic>.from(images);
    final preview = imageMap['fixed_width_small'] ?? imageMap['downsized'];
    final full =
        imageMap['original'] ?? imageMap['downsized_medium'] ?? preview;
    if (preview is! Map || full is! Map) return null;

    final previewUrl = preview['url']?.toString().trim() ?? '';
    final gifUrl = full['url']?.toString().trim() ?? '';
    if (previewUrl.isEmpty || gifUrl.isEmpty) return null;

    return GifResult(
      id: data['id']?.toString() ?? gifUrl,
      title: data['title']?.toString() ?? 'GIPHY GIF',
      previewUrl: previewUrl,
      gifUrl: gifUrl,
    );
  }
}
