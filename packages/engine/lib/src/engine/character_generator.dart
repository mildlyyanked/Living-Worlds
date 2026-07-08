/// Character generation (§ character onboarding).
///
/// A new character starts from one paragraph of player seeding text. The model
/// turns it — together with the world's basic bio — into a compact, structured
/// character bio (kept permanently in context), an opening scenario, and,
/// where the background warrants it, a starting quest.
///
/// Like everything at the model→engine boundary this is tolerant: a prose or
/// malformed reply degrades to a usable fallback instead of throwing.
library;

import 'dart:convert';

import '../llm/llm_client.dart';
import '../model/quest.dart';

/// The engine-ready result of generating a character from seeding text.
class GeneratedCharacter {
  const GeneratedCharacter({
    required this.bio,
    required this.openingScenario,
    this.startingQuest,
  });

  /// Compact, structured bio (appearance / personality / status / background).
  final String bio;

  /// The character's opening situation, shown as the first scene of gameplay.
  final String openingScenario;

  /// Optional quest seeded from the character's background.
  final Quest? startingQuest;
}

class CharacterGenerator {
  const CharacterGenerator({required this.llm});

  final LlmClient llm;

  static const String _systemPrompt = '''
You design a playable character for a living-world life-sim from one paragraph
of player seeding text, staying consistent with the world's basic bio. Return
STRICT JSON only — no prose outside the JSON:
{
  "bio": {
    "appearance": "<one or two sentences, mostly physical features>",
    "personality": "<key traits>",
    "status": "<societal status / role / standing>",
    "background": "<concise origin relevant to play>"
  },
  "opening_scenario": "<a vivid second-person opening situation grounded in the
     bio and the world; 2-4 sentences; do NOT resolve it — leave the player to
     act>",
  "starting_quest": null OR {
    "title": "<short goal drawn from the background>",
    "steps": ["<first concrete step>", "<second step>"]
  }
}
Keep the bio dense and efficient — it is permanent context. Only include a
starting_quest when the background clearly implies an unfinished goal;
otherwise use null.''';

  Future<GeneratedCharacter> generate({
    required String name,
    required String seedParagraph,
    required String worldName,
    required String worldBio,
  }) async {
    final prompt = [
      'WORLD: $worldName',
      if (worldBio.trim().isNotEmpty) 'WORLD BASIC BIO:\n$worldBio',
      'NEW CHARACTER NAME: $name',
      'PLAYER SEEDING TEXT:\n$seedParagraph',
    ].join('\n\n');

    String raw;
    try {
      raw = await llm.complete(
        systemPrompt: _systemPrompt,
        prompt: prompt,
        expectJson: true,
      );
    } catch (_) {
      return _fallback(name, seedParagraph, worldName);
    }
    return _parse(raw, name, seedParagraph, worldName);
  }

  GeneratedCharacter _parse(
    String raw,
    String name,
    String seedParagraph,
    String worldName,
  ) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '')
          .trim();
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // Salvage an embedded object, else treat the whole reply as the bio.
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          decoded = jsonDecode(text.substring(start, end + 1));
        } catch (_) {}
      }
    }
    if (decoded is! Map<String, Object?>) {
      return _fallback(name, seedParagraph, worldName,
          bioOverride: raw.trim().isEmpty ? null : raw.trim());
    }

    final bio = _composeBio(decoded['bio'], seedParagraph);
    final scenario = (decoded['opening_scenario'] as String?)?.trim();
    return GeneratedCharacter(
      bio: bio,
      openingScenario: (scenario == null || scenario.isEmpty)
          ? _fallbackScenario(name, worldName)
          : scenario,
      startingQuest: _parseQuest(decoded['starting_quest'], name),
    );
  }

  String _composeBio(Object? bioField, String seedParagraph) {
    if (bioField is Map<String, Object?>) {
      String field(String k) => (bioField[k] as String?)?.trim() ?? '';
      final parts = <String>[
        if (field('appearance').isNotEmpty) 'Appearance: ${field('appearance')}',
        if (field('personality').isNotEmpty)
          'Personality: ${field('personality')}',
        if (field('status').isNotEmpty) 'Status: ${field('status')}',
        if (field('background').isNotEmpty) 'Background: ${field('background')}',
      ];
      if (parts.isNotEmpty) return parts.join('\n');
    }
    if (bioField is String && bioField.trim().isNotEmpty) return bioField.trim();
    return seedParagraph.trim();
  }

  Quest? _parseQuest(Object? questField, String name) {
    if (questField is! Map<String, Object?>) return null;
    final title = (questField['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) return null;
    final rawSteps = questField['steps'];
    final steps = <QuestStep>[];
    if (rawSteps is List) {
      var i = 0;
      for (final s in rawSteps) {
        final desc = s is String ? s.trim() : '$s'.trim();
        if (desc.isEmpty) continue;
        steps.add(QuestStep(id: 'step-${++i}', desc: desc));
      }
    }
    if (steps.isEmpty) {
      steps.add(QuestStep(id: 'step-1', desc: title));
    }
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    // No rewards: generated quests reference no guaranteed item definitions.
    return Quest(id: 'quest-$slug-start', title: title, steps: steps);
  }

  GeneratedCharacter _fallback(
    String name,
    String seedParagraph,
    String worldName, {
    String? bioOverride,
  }) =>
      GeneratedCharacter(
        bio: (bioOverride ?? seedParagraph).trim().isEmpty
            ? 'A newcomer to $worldName.'
            : (bioOverride ?? seedParagraph).trim(),
        openingScenario: _fallbackScenario(name, worldName),
      );

  String _fallbackScenario(String name, String worldName) =>
      'You are $name. $worldName stretches out around you, indifferent and '
      'full of possibility. What do you do first?';
}
