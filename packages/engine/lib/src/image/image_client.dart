/// Image generation seam (§ images). Like [LlmClient]/[EmbeddingClient], the
/// game talks to an abstract [ImageClient]; production uses Perchance, tests
/// use a fixture. Serverless by design: the client calls the provider directly
/// (Perchance is keyless — no secret to protect), and every endpoint detail is
/// configurable so the maintenance is self-serve when the provider drifts.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// A generated image: raw bytes plus a mime type for rendering/persistence.
class GeneratedImage {
  const GeneratedImage({required this.bytes, this.mimeType = 'image/jpeg'});

  final Uint8List bytes;
  final String mimeType;
}

class ImageGenerationException implements Exception {
  const ImageGenerationException(this.message);
  final String message;
  @override
  String toString() => 'ImageGenerationException: $message';
}

abstract class ImageClient {
  /// Generate an image for [prompt]. Throws [ImageGenerationException] on
  /// failure so the UI can surface a fixable message (e.g. "refresh userKey").
  Future<GeneratedImage> generate(String prompt, {String negativePrompt = ''});
}

/// Every knob of the Perchance image flow, so the whole contract can be edited
/// from Settings without a rebuild. Placeholders in [queryTemplate]:
/// `{prompt}`, `{negativePrompt}`, `{seed}`, `{resolution}`, `{guidance}`,
/// `{userKey}`, `{cacheBust}`, `{requestId}`.
class PerchanceImageConfig {
  const PerchanceImageConfig({
    this.baseUrl = 'https://image-generation.perchance.org/api',
    this.generatePath = '/generate',
    this.downloadPath = '/downloadTemporaryImage',
    this.queryTemplate =
        'prompt={prompt}&negativePrompt={negativePrompt}&seed={seed}'
            '&resolution={resolution}&guidanceScale={guidance}'
            '&channel=ai-text-to-image-generator&subChannel=public'
            '&userKey={userKey}&requestId={requestId}&__cacheBust={cacheBust}',
    this.downloadQueryTemplate = 'imageId={imageId}',
    this.imageIdField = 'imageId',
    this.statusField = 'status',
    this.okStatus = 'success',
    this.userKey = '',
    this.resolution = '512x512',
    this.guidanceScale = 7.0,
  });

  final String baseUrl;
  final String generatePath;
  final String downloadPath;
  final String queryTemplate;
  final String downloadQueryTemplate;

  /// JSON field in the generate response holding the temporary image id.
  final String imageIdField;

  /// JSON field + value indicating success (blank [statusField] skips check).
  final String statusField;
  final String okStatus;

  /// Verification token pasted from the browser (self-serve maintenance).
  final String userKey;
  final String resolution;
  final double guidanceScale;

  PerchanceImageConfig copyWith({
    String? baseUrl,
    String? generatePath,
    String? downloadPath,
    String? queryTemplate,
    String? downloadQueryTemplate,
    String? imageIdField,
    String? statusField,
    String? okStatus,
    String? userKey,
    String? resolution,
    double? guidanceScale,
  }) =>
      PerchanceImageConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        generatePath: generatePath ?? this.generatePath,
        downloadPath: downloadPath ?? this.downloadPath,
        queryTemplate: queryTemplate ?? this.queryTemplate,
        downloadQueryTemplate:
            downloadQueryTemplate ?? this.downloadQueryTemplate,
        imageIdField: imageIdField ?? this.imageIdField,
        statusField: statusField ?? this.statusField,
        okStatus: okStatus ?? this.okStatus,
        userKey: userKey ?? this.userKey,
        resolution: resolution ?? this.resolution,
        guidanceScale: guidanceScale ?? this.guidanceScale,
      );

  Map<String, Object?> toJson() => {
        'base_url': baseUrl,
        'generate_path': generatePath,
        'download_path': downloadPath,
        'query_template': queryTemplate,
        'download_query_template': downloadQueryTemplate,
        'image_id_field': imageIdField,
        'status_field': statusField,
        'ok_status': okStatus,
        'user_key': userKey,
        'resolution': resolution,
        'guidance_scale': guidanceScale,
      };

  factory PerchanceImageConfig.fromJson(Map<String, Object?> json) {
    const d = PerchanceImageConfig();
    return PerchanceImageConfig(
      baseUrl: json['base_url'] as String? ?? d.baseUrl,
      generatePath: json['generate_path'] as String? ?? d.generatePath,
      downloadPath: json['download_path'] as String? ?? d.downloadPath,
      queryTemplate: json['query_template'] as String? ?? d.queryTemplate,
      downloadQueryTemplate:
          json['download_query_template'] as String? ?? d.downloadQueryTemplate,
      imageIdField: json['image_id_field'] as String? ?? d.imageIdField,
      statusField: json['status_field'] as String? ?? d.statusField,
      okStatus: json['ok_status'] as String? ?? d.okStatus,
      userKey: json['user_key'] as String? ?? d.userKey,
      resolution: json['resolution'] as String? ?? d.resolution,
      guidanceScale:
          (json['guidance_scale'] as num?)?.toDouble() ?? d.guidanceScale,
    );
  }
}

/// Serverless, config-driven Perchance client. Two GETs: `generate` (returns a
/// temporary image id) then `download` (returns the bytes). The verification
/// `userKey` is supplied by config (pasted from a browser), so the anti-bot
/// handshake never has to happen on-device.
class PerchanceImageClient implements ImageClient {
  PerchanceImageClient({required this.config, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final PerchanceImageConfig config;
  final http.Client _http;
  int _seq = 0;

  String _fill(String tmpl, Map<String, String> vars) {
    var s = tmpl;
    vars.forEach((k, v) {
      s = s.replaceAll('{$k}', Uri.encodeQueryComponent(v));
    });
    return s;
  }

  @override
  Future<GeneratedImage> generate(String prompt,
      {String negativePrompt = ''}) async {
    if (config.userKey.trim().isEmpty) {
      throw const ImageGenerationException(
          'no Perchance userKey set — paste one in Settings (get it from the '
          'generator page in a browser).');
    }
    final cacheBust = DateTime.now().millisecondsSinceEpoch.toString();
    final requestId = '${cacheBust}_${_seq++}';
    final query = _fill(config.queryTemplate, {
      'prompt': prompt,
      'negativePrompt': negativePrompt,
      'seed': '-1',
      'resolution': config.resolution,
      'guidance': config.guidanceScale.toString(),
      'userKey': config.userKey,
      'requestId': requestId,
      'cacheBust': cacheBust,
    });
    final genUri = Uri.parse('${config.baseUrl}${config.generatePath}?$query');
    final genResp = await _http.get(genUri);
    if (genResp.statusCode != 200) {
      throw ImageGenerationException(
          'generate failed (${genResp.statusCode}): ${genResp.body}');
    }
    Map<String, Object?> json;
    try {
      json = jsonDecode(genResp.body) as Map<String, Object?>;
    } catch (_) {
      throw ImageGenerationException(
          'unexpected generate response: ${genResp.body}');
    }
    if (config.statusField.isNotEmpty &&
        json[config.statusField] != null &&
        '${json[config.statusField]}' != config.okStatus) {
      throw ImageGenerationException('Perchance returned ${config.statusField}='
          '${json[config.statusField]} (userKey may be invalid/expired).');
    }
    final imageId = json[config.imageIdField];
    if (imageId == null || '$imageId'.isEmpty) {
      throw ImageGenerationException(
          'no ${config.imageIdField} in response: ${genResp.body}');
    }
    final dlQuery =
        _fill(config.downloadQueryTemplate, {'imageId': '$imageId'});
    final dlUri = Uri.parse('${config.baseUrl}${config.downloadPath}?$dlQuery');
    final dlResp = await _http.get(dlUri);
    if (dlResp.statusCode != 200 || dlResp.bodyBytes.isEmpty) {
      throw ImageGenerationException(
          'image download failed (${dlResp.statusCode}).');
    }
    final mime = dlResp.headers['content-type'] ?? 'image/jpeg';
    return GeneratedImage(bytes: dlResp.bodyBytes, mimeType: mime);
  }
}

/// Deterministic fixture for tests/offline: returns canned bytes without any
/// network. A 1x1 PNG by default.
class FixtureImageClient implements ImageClient {
  FixtureImageClient({Uint8List? bytes}) : _bytes = bytes ?? _onePixelPng;

  final Uint8List _bytes;
  final List<String> prompts = [];

  static final Uint8List _onePixelPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

  @override
  Future<GeneratedImage> generate(String prompt,
      {String negativePrompt = ''}) async {
    prompts.add(prompt);
    return GeneratedImage(bytes: _bytes, mimeType: 'image/png');
  }
}
