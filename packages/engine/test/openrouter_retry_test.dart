/// The OpenRouter client retries transient transport failures (dropped
/// connections, timeouts) so a single network blip — e.g. the app being
/// backgrounded mid-request — doesn't fail the whole turn.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:test/test.dart';

class _NoTools implements LlmToolHandler {
  @override
  Future<Object?> handle(LlmToolCall call) async => {};
}

String _okBody() => jsonEncode({
      'choices': [
        {
          'message': {
            'content': jsonEncode({'narrative': 'ok', 'proposed_deltas': {}}),
          }
        }
      ],
      'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
    });

void main() {
  test('a dropped connection is retried, then the turn succeeds', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      if (calls < 3) {
        throw http.ClientException('Connection closed while receiving data');
      }
      return http.Response(_okBody(), 200);
    });
    final client = OpenRouterLlmClient(
      baseUrl: 'https://openrouter.test/api/v1',
      httpClient: mock,
      retryBackoff: Duration.zero,
    );
    final result = await client.completeTurn(
      systemPrompt: 's',
      context: 'c',
      userInput: 'go',
      tools: _NoTools(),
    );
    expect(result.output.narrative, 'ok');
    expect(calls, 3, reason: 'two failures then a success');
  });

  test('gives up after maxRetries with a clear LlmException', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      throw http.ClientException('Connection closed while receiving data');
    });
    final client = OpenRouterLlmClient(
      baseUrl: 'https://openrouter.test/api/v1',
      httpClient: mock,
      maxRetries: 2,
      retryBackoff: Duration.zero,
    );
    await expectLater(
      client.completeTurn(
        systemPrompt: 's',
        context: 'c',
        userInput: 'go',
        tools: _NoTools(),
      ),
      throwsA(isA<LlmException>()),
    );
    expect(calls, 3, reason: '1 initial attempt + 2 retries');
  });

  test('an HTTP error status is not retried (surfaces immediately)', () async {
    var calls = 0;
    final mock = MockClient((req) async {
      calls++;
      return http.Response('rate limited', 429);
    });
    final client = OpenRouterLlmClient(
      baseUrl: 'https://openrouter.test/api/v1',
      httpClient: mock,
      retryBackoff: Duration.zero,
    );
    await expectLater(
      client.completeTurn(
        systemPrompt: 's',
        context: 'c',
        userInput: 'go',
        tools: _NoTools(),
      ),
      throwsA(isA<LlmException>()),
    );
    expect(calls, 1, reason: 'HTTP statuses are not transient — no retry');
  });
}
