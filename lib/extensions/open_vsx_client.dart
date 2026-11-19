/// REST client for the Open VSX marketplace (https://open-vsx.org).
/// Used to search, read metadata and retrieve .vsix files.
///
/// API docs : https://open-vsx.org/swagger-ui/index.html
library;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models/marketplace_extension.dart';





class OpenVsxClient {
  static const String _baseUrl = 'https://open-vsx.org';
  static const Duration _timeout = Duration(seconds: 15);

  final http.Client _http;

  OpenVsxClient({http.Client? client}) : _http = client ?? http.Client();

  // ── Recherche ────────────────────────────────────────────────────────────

  /// Search for extensions by text.
  /// [query]    : texte libre
  /// [offset] : pagination (default 0)
  /// [size] : number of results per page (max 50 server-side)
  /// [category] : category filter (e.g., "Programming Languages")
  /// [sortBy]   : "relevance" | "timestamp" | "downloadCount" | "rating"
  Future<MarketplaceSearchResult> search({
    required String query,
    int offset = 0,
    int size = 20,
    String? category,
    String sortBy = 'relevance',
  }) async {
    final uri = Uri.parse('$_baseUrl/api/-/search').replace(queryParameters: {
      'query': query,
      'offset': offset.toString(),
      'size': size.toString(),
      'sortBy': sortBy,
      'category': ?category,
    });

    final response = await _http
        .get(uri, headers: _headers)
        .timeout(_timeout);

    _assertOk(response, 'search');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return MarketplaceSearchResult.fromJson(json);
  }

  /// Searches for the most downloaded extensions (marketplace homepage).
  Future<MarketplaceSearchResult> featured({int size = 20}) async {
    return search(query: '', sortBy: 'downloadCount', size: size);
  }

  // ── Metadata of an extension ────────────────────────────────────────────

  /// Retrieves metadata from the latest version of an extension.
  Future<MarketplaceExtension> getExtension(
      String namespace, String name) async {
    final uri = Uri.parse('$_baseUrl/api/$namespace/$name');
    final response = await _http
        .get(uri, headers: _headers)
        .timeout(_timeout);

    _assertOk(response, 'getExtension $namespace.$name');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return MarketplaceExtension.fromSearchJson(json);
  }

  /// Retrieves metadata for a specific version.
  Future<MarketplaceExtension> getExtensionVersion(
      String namespace, String name, String version) async {
    final uri = Uri.parse('$_baseUrl/api/$namespace/$name/linux-arm64/$version');
    http.Response response;
    try {
      response = await _http.get(uri, headers: _headers).timeout(_timeout);
    } catch (_) {
      // Fallback sans platform
      final fallback = Uri.parse('$_baseUrl/api/$namespace/$name/$version');
      response = await _http.get(fallback, headers: _headers).timeout(_timeout);
    }

    _assertOk(response, 'getExtensionVersion $namespace.$name@$version');
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return MarketplaceExtension.fromSearchJson(json);
  }

  // ── Download URL ────────────────────────────────────────────────────

  /// Returns the download URL for the .vsix file for an extension.
  /// Prefers the linux-arm64 version if available, otherwise universal.
  Future<String> getDownloadUrl(
      String namespace, String name, String version) async {
    // Try the arm64 variant first (better Android compatibility)
    final arm64 = Uri.parse(
        '$_baseUrl/api/$namespace/$name/linux-arm64/$version/file/$namespace.$name-$version@linux-arm64.vsix');

    try {
      final r = await _http.head(arm64, headers: _headers).timeout(_timeout);
      if (r.statusCode == 200) return arm64.toString();
    } catch (_) {}

    // Fallback universal
    return '$_baseUrl/api/$namespace/$name/linux-x64/$version/file/$namespace.$name-$version.vsix';
  }

  /// Simplified URL — directly constructs the URL without a prior HEAD request.
  static String quickDownloadUrl(
      String namespace, String name, String version) {
    return '$_baseUrl/api/$namespace/$name/$version/file/$namespace.$name-$version.vsix';
  }

  // ── README ───────────────────────────────────────────────────────────────

  /// Retrieves the README.md of an extension (markdown text).
  Future<String?> getReadme(
      String namespace, String name, String version) async {
    // Open VSX exposes the actual file name in the version metadata. Some
    // extensions publish `readme.md` (lowercase), so assuming README.md
    // makes the detail page silently empty on case-sensitive registries.
    try {
      final metadataUri =
          Uri.parse('$_baseUrl/api/$namespace/$name/$version');
      final metadataResponse =
          await _http.get(metadataUri, headers: _headers).timeout(_timeout);
      if (metadataResponse.statusCode >= 200 &&
          metadataResponse.statusCode < 300) {
        final metadata =
            jsonDecode(metadataResponse.body) as Map<String, dynamic>;
        final files = metadata['files'];
        final readmeUrl =
            files is Map ? files['readme']?.toString() : null;
        if (readmeUrl != null && readmeUrl.isNotEmpty) {
          final content = await _getText(readmeUrl);
          if (content != null && content.trim().isNotEmpty) return content;
        }
      }
    } catch (_) {
      // Try the conventional paths below. A missing metadata response should
      // never make the whole extension detail page fail.
    }

    for (final fileName in const ['README.md', 'readme.md']) {
      final uri = Uri.parse(
          '$_baseUrl/api/$namespace/$name/$version/file/$fileName');
      final content = await _getText(uri.toString());
      if (content != null && content.trim().isNotEmpty) return content;
    }
    return null;
  }

  Future<String?> _getText(String url) async {
    try {
      final response = await _http
          .get(Uri.parse(url), headers: const {
            'Accept': 'text/plain, text/markdown, text/html, */*',
            'User-Agent': 'PandaIDE/2.3 (Android; arm64)',
          })
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body;
      }
    } catch (_) {}
    return null;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static const Map<String, String> _headers = {
    'Accept': 'application/json',
    'User-Agent': 'PandaIDE/2.3 (Android; arm64)',
  };

  void _assertOk(http.Response r, String ctx) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('Open VSX API error [$ctx]: HTTP ${r.statusCode}\n${r.body}');
    }
  }

  void dispose() => _http.close();
}
