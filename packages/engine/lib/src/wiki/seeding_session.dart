/// Seeding session (§5.1): a ChatGPT-style behind-the-scenes workshop whose
/// only job is creating/updating wiki entries. The model may ask clarifying
/// questions; accepted output becomes a WikiCreated/WikiUpdated event.
/// Distinct from gameplay: no clock advance, no death, no character state.
library;

import 'dart:convert';

import '../engine/world_service.dart';
import '../llm/llm_client.dart';
import '../model/event.dart';
import '../model/wiki.dart';
import '../repo/world_repository.dart';

enum SeedingActionKind { clarify, proposeCreate, proposeUpdate, chat }

/// The model's move in the workshop conversation.
class SeedingAction {
  const SeedingAction({
    required this.kind,
    this.message = '',
    this.entry,
  });

  final SeedingActionKind kind;

  /// Clarifying question or plain reply.
  final String message;

  /// The proposed entry for proposeCreate/proposeUpdate.
  final WikiEntry? entry;
}

class SeedingSession {
  SeedingSession({
    required this.repo,
    required this.llm,
    required this.worldId,
    DateTime Function()? clock,
  }) : service = WorldService(repo, clock: clock);

  final WorldRepository repo;
  final LlmClient llm;
  final String worldId;
  final WorldService service;

  final List<({String role, String text})> transcript = [];

  String _systemPrompt(List<String> categories) => '''
You are a world-building workshop assistant. Your only job is to create and
refine encyclopedia (wiki) entries for a fictional world. Ask clarifying
questions when an idea is underspecified. Never advance time or touch
character state. Respond with strict JSON, one of:
{"action":"clarify","message":"<your question>"}
{"action":"chat","message":"<short reply>"}
{"action":"propose_create","entry":{"title":"","category":"<one of: ${categories.join(' | ')}>","body":"","tags":[],"clock_ref":null}}
{"action":"propose_update","entry":{"id":"<existing id>","title":"","category":"","body":"","tags":[],"clock_ref":null}}''';

  /// One workshop exchange: user says something, model replies with a
  /// clarifying question, chat, or a proposed entry (not yet committed).
  Future<SeedingAction> send(String userMessage) async {
    final projection = await repo.projection();
    final categories =
        projection.world?.schema.wikiCategories ?? const <String>[];
    transcript.add((role: 'user', text: userMessage));

    final existing = projection.wiki.values
        .map((w) => '- ${w.id}: ${w.summaryLine}')
        .join('\n');
    final prompt = [
      if (existing.isNotEmpty) 'EXISTING ENTRIES:\n$existing',
      for (final t in transcript) '${t.role}: ${t.text}',
    ].join('\n');

    final raw = await llm.complete(
      systemPrompt: _systemPrompt(categories),
      prompt: prompt,
      expectJson: true,
    );
    transcript.add((role: 'assistant', text: raw));
    return _parse(raw, projection.wiki);
  }

  SeedingAction _parse(String raw, Map<String, WikiEntry> wiki) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '');
    }
    final json = jsonDecode(text) as Map<String, Object?>;
    final action = json['action'] as String? ?? 'chat';
    switch (action) {
      case 'clarify':
        return SeedingAction(
            kind: SeedingActionKind.clarify,
            message: json['message'] as String? ?? '');
      case 'propose_create':
      case 'propose_update':
        final e = json['entry'] as Map<String, Object?>;
        final isUpdate = action == 'propose_update';
        final id = e['id'] as String? ??
            'wiki-${(e['title'] as String? ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';
        final base = isUpdate ? wiki[id] : null;
        return SeedingAction(
          kind: isUpdate
              ? SeedingActionKind.proposeUpdate
              : SeedingActionKind.proposeCreate,
          entry: WikiEntry(
            id: id,
            worldId: worldId,
            title: e['title'] as String? ?? base?.title ?? '',
            category: e['category'] as String? ?? base?.category ?? '',
            body: e['body'] as String? ?? base?.body ?? '',
            tags: [
              for (final t in e['tags'] as List<Object?>? ?? <Object?>[])
                t! as String
            ],
            clockRef: e['clock_ref'] as int? ?? base?.clockRef,
            version: base?.version ?? 1,
          ),
        );
      default:
        return SeedingAction(
            kind: SeedingActionKind.chat,
            message: json['message'] as String? ?? '');
    }
  }

  /// User accepts a proposal: commit it as an event (change-log
  /// write-through, §5.1). Returns the committed event.
  Future<Event> accept(SeedingAction action) {
    final entry = action.entry;
    if (entry == null) {
      throw ArgumentError('accept: action carries no entry');
    }
    final cause = {'seeding_transcript_tail': transcript.length};
    return switch (action.kind) {
      SeedingActionKind.proposeCreate =>
        service.createWikiEntry(entry, cause: cause),
      SeedingActionKind.proposeUpdate =>
        service.updateWikiEntry(entry, cause: cause),
      _ => throw ArgumentError('accept: ${action.kind} is not a proposal'),
    };
  }
}
