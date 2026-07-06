/// Production LLM client: OpenRouter chat completions with a native tool
/// loop and strict-JSON final output (§2), plus usage/cost capture (§10).
///
/// API keys never touch the client in production (§7): point [baseUrl] at
/// the Supabase Edge Function proxy and leave [apiKey] null. In pure-local
/// dev mode a direct key is acceptable behind a debug flag — pass [apiKey].
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../retrieval/embedding_client.dart';
import 'contract.dart';
import 'llm_client.dart';

class OpenRouterLlmClient implements LlmClient {
  OpenRouterLlmClient({
    required this.baseUrl,
    this.apiKey,
    this.model = 'anthropic/claude-sonnet-4.5',
    this.maxToolRounds = 6,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// Either the OpenRouter API root or the Edge Function proxy root; both
  /// speak the same chat-completions dialect.
  final String baseUrl;
  final String? apiKey;

  /// Pinned tool-calling-reliable model (§14).
  final String model;
  final int maxToolRounds;
  final http.Client _http;

  static const _toolDefs = [
    {
      'type': 'function',
      'function': {
        'name': 'query_wiki',
        'description': 'Look up wiki entries by title, category or free text.',
        'parameters': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'category': {'type': 'string'},
            'free_text': {'type': 'string'},
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_relationship',
        'description': 'Fetch relationship edges touching char_a (and '
            'optionally char_b).',
        'parameters': {
          'type': 'object',
          'properties': {
            'char_a': {'type': 'string'},
            'char_b': {'type': 'string'},
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'query_inventory',
        'description': 'List a character\'s items with affordances.',
        'parameters': {
          'type': 'object',
          'properties': {
            'char_id': {'type': 'string'},
          },
          'required': ['char_id'],
        },
      },
    },
  ];

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null) 'Authorization': 'Bearer $apiKey',
      };

  @override
  Future<LlmTurnResult> completeTurn({
    required String systemPrompt,
    required String context,
    required String userInput,
    required LlmToolHandler tools,
  }) async {
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': '$context\n\nPLAYER: $userInput'},
    ];
    final exchanges = <LlmToolExchange>[];
    var promptTokens = 0, completionTokens = 0, latencyMs = 0;
    var cost = 0.0;

    for (var round = 0; round <= maxToolRounds; round++) {
      final started = DateTime.now();
      final resp = await _http.post(
        Uri.parse('$baseUrl/chat/completions'),
        headers: _headers,
        body: jsonEncode({
          'model': model,
          'messages': messages,
          'tools': _toolDefs,
          // Force strict JSON on the final message.
          'response_format': {'type': 'json_object'},
          'usage': {'include': true},
        }),
      );
      latencyMs += DateTime.now().difference(started).inMilliseconds;
      if (resp.statusCode != 200) {
        throw LlmException(
            'OpenRouter ${resp.statusCode}: ${resp.body}');
      }
      final json = jsonDecode(resp.body) as Map<String, Object?>;
      final usage = json['usage'] as Map<String, Object?>? ?? const {};
      promptTokens += (usage['prompt_tokens'] as num? ?? 0).toInt();
      completionTokens += (usage['completion_tokens'] as num? ?? 0).toInt();
      cost += (usage['cost'] as num? ?? 0).toDouble();

      final choice =
          (json['choices'] as List<Object?>).first! as Map<String, Object?>;
      final message = choice['message'] as Map<String, Object?>;
      final toolCalls = message['tool_calls'] as List<Object?>?;

      if (toolCalls == null || toolCalls.isEmpty) {
        final content = message['content'] as String? ?? '{}';
        return LlmTurnResult(
          output: parseTurnOutput(content),
          toolExchanges: exchanges,
          usage: LlmUsage(
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            computedCostUsd: cost,
            latencyMs: latencyMs,
          ),
          rawJson: content,
        );
      }

      messages.add(message);
      for (final tc in toolCalls) {
        final call = tc! as Map<String, Object?>;
        final fn = call['function'] as Map<String, Object?>;
        final llmCall = LlmToolCall(
          name: fn['name'] as String,
          args: (jsonDecode(fn['arguments'] as String? ?? '{}')
              as Map<String, Object?>),
        );
        final result = await tools.handle(llmCall);
        exchanges.add(LlmToolExchange(call: llmCall, result: result));
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': jsonEncode(result),
        });
      }
    }
    throw LlmException(
        'tool loop exceeded $maxToolRounds rounds without a final answer');
  }

  @override
  Future<String> complete({
    required String systemPrompt,
    required String prompt,
    bool expectJson = false,
  }) async {
    final resp = await _http.post(
      Uri.parse('$baseUrl/chat/completions'),
      headers: _headers,
      body: jsonEncode({
        'model': model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': prompt},
        ],
        if (expectJson) 'response_format': {'type': 'json_object'},
      }),
    );
    if (resp.statusCode != 200) {
      throw LlmException('OpenRouter ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, Object?>;
    final choice =
        (json['choices'] as List<Object?>).first! as Map<String, Object?>;
    return (choice['message'] as Map<String, Object?>)['content'] as String? ??
        '';
  }

  /// Tolerant strict-JSON parse: strips code fences, then decodes the
  /// contract shape. Malformed output throws — the turn controller treats
  /// that as a failed (uncommitted) turn.
  static TurnOutput parseTurnOutput(String raw) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '');
    }
    return TurnOutput.fromJson(jsonDecode(text) as Map<String, Object?>);
  }
}

/// Production embedding client via OpenRouter/OpenAI-compatible endpoint.
class OpenRouterEmbeddingClient implements EmbeddingClient {
  OpenRouterEmbeddingClient({
    required this.baseUrl,
    this.apiKey,
    this.model = 'openai/text-embedding-3-small',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String? apiKey;
  final String model;
  final http.Client _http;
  int _lastTokens = 0;

  @override
  int get lastTokenCount => _lastTokens;

  @override
  Future<List<double>> embed(String text) async {
    final resp = await _http.post(
      Uri.parse('$baseUrl/embeddings'),
      headers: {
        'Content-Type': 'application/json',
        if (apiKey != null) 'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({'model': model, 'input': text}),
    );
    if (resp.statusCode != 200) {
      throw LlmException('embeddings ${resp.statusCode}: ${resp.body}');
    }
    final json = jsonDecode(resp.body) as Map<String, Object?>;
    _lastTokens = ((json['usage'] as Map<String, Object?>?)?['total_tokens']
                as num? ??
            0)
        .toInt();
    final data =
        (json['data'] as List<Object?>).first! as Map<String, Object?>;
    return [
      for (final v in data['embedding'] as List<Object?>) (v! as num).toDouble()
    ];
  }
}

class LlmException implements Exception {
  const LlmException(this.message);

  final String message;

  @override
  String toString() => 'LlmException: $message';
}
