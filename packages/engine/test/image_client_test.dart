/// The Perchance image client is serverless and fully config-driven: a
/// generate GET (temporary image id) then a download GET (bytes). The
/// verification userKey is supplied by config, never solved on-device.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

void main() {
  final pngBytes = Uint8List.fromList([1, 2, 3, 4]);

  test('missing userKey fails with a fixable message', () async {
    final client = PerchanceImageClient(
      config: const PerchanceImageConfig(), // userKey empty
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    await expectLater(
      client.generate('a harbor at dawn'),
      throwsA(isA<ImageGenerationException>()
          .having((e) => e.message, 'message', contains('userKey'))),
    );
  });

  test('generate then download returns the image bytes', () async {
    final seen = <Uri>[];
    final mock = MockClient((req) async {
      seen.add(req.url);
      if (req.url.path.endsWith('/generate')) {
        return http.Response(
            jsonEncode({'status': 'success', 'imageId': 'img-123'}), 200);
      }
      return http.Response.bytes(pngBytes, 200,
          headers: {'content-type': 'image/jpeg'});
    });
    final client = PerchanceImageClient(
      config: const PerchanceImageConfig(userKey: 'abc'),
      httpClient: mock,
    );
    final img =
        await client.generate('a drowned tunnel', negativePrompt: 'blur');

    expect(img.bytes, pngBytes);
    expect(img.mimeType, 'image/jpeg');
    // Prompt + userKey went out on the generate call; download used the id.
    expect(seen[0].query, contains('prompt=a+drowned+tunnel'));
    expect(seen[0].query, contains('userKey=abc'));
    expect(seen[1].query, contains('imageId=img-123'));
  });

  test('a non-success status is reported as a key problem', () async {
    final client = PerchanceImageClient(
      config: const PerchanceImageConfig(userKey: 'stale'),
      httpClient: MockClient((_) async =>
          http.Response(jsonEncode({'status': 'invalid_key'}), 200)),
    );
    await expectLater(
      client.generate('x'),
      throwsA(isA<ImageGenerationException>()),
    );
  });

  test('config round-trips through JSON (self-serve settings)', () {
    const c = PerchanceImageConfig(userKey: 'k', resolution: '768x768');
    final back = PerchanceImageConfig.fromJson(
        jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>);
    expect(back.userKey, 'k');
    expect(back.resolution, '768x768');
    expect(back.queryTemplate, c.queryTemplate);
  });

  test('fixture client returns canned bytes and records prompts', () async {
    final f = FixtureImageClient();
    final img = await f.generate('a mural');
    expect(img.bytes, isNotEmpty);
    expect(f.prompts.single, 'a mural');
  });
}
