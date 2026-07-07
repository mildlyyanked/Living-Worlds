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

enum SeedingActionKind { clarify, chat, propose }

/// One proposed wiki entry within a response. A single response may carry
/// several, each accepted/committed independently.
class SeedingProposal {
  const SeedingProposal({required this.entry, required this.isUpdate});

  final WikiEntry entry;
  final bool isUpdate;
}

/// The model's move in the workshop conversation.
class SeedingAction {
  const SeedingAction({
    required this.kind,
    this.message = '',
    this.proposals = const [],
  });

  final SeedingActionKind kind;

  /// Clarifying question or plain reply.
  final String message;

  /// Proposed entries (possibly several) for [SeedingActionKind.propose].
  final List<SeedingProposal> proposals;
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
character state.

Respond with STRICT JSON only — no prose outside the JSON — as one of:
{"action":"clarify","message":"<your question>"}
{"action":"chat","message":"<short reply>"}
{"action":"propose","entries":[
  {"op":"create","title":"","category":"<one of: ${categories.join(' | ')}>","body":"","tags":[],"clock_ref":null},
  {"op":"update","id":"<existing id>","title":"","category":"","body":"","tags":[],"clock_ref":null}
]}
You MAY include several entries in one "propose" — the user accepts each
separately. Prefer "propose" once you have enough detail.''';

  /// One workshop exchange: user says something, model replies with a
  /// clarifying question, chat, or one-or-more proposed entries (uncommitted).
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

  /// Tolerant parse: models sometimes reply in prose despite the JSON
  /// instruction. Any non-JSON (or unrecognized) response degrades to a chat
  /// bubble showing the model's text rather than throwing (the reported
  /// FormatException).
  SeedingAction _parse(String raw, Map<String, WikiEntry> wiki) {
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
      // Not JSON at all — treat the whole reply as conversational.
      return SeedingAction(kind: SeedingActionKind.chat, message: raw.trim());
    }
    if (decoded is! Map<String, Object?>) {
      return SeedingAction(kind: SeedingActionKind.chat, message: raw.trim());
    }
    final json = decoded;
    final action = json['action'] as String? ?? 'chat';

    switch (action) {
      case 'clarify':
        return SeedingAction(
          kind: SeedingActionKind.clarify,
          message: json['message'] as String? ?? '',
        );

      case 'propose':
        final rawEntries = json['entries'];
        final proposals = <SeedingProposal>[
          if (rawEntries is List)
            for (final e in rawEntries)
              if (e is Map<String, Object?>) _proposal(e, wiki),
          // Back-compat: a single "entry" object under "propose".
          if (json['entry'] is Map<String, Object?>)
            _proposal(json['entry']! as Map<String, Object?>, wiki),
        ];
        if (proposals.isEmpty) {
          return SeedingAction(
            kind: SeedingActionKind.chat,
            message: json['message'] as String? ?? raw.trim(),
          );
        }
        return SeedingAction(
          kind: SeedingActionKind.propose,
          message: json['message'] as String? ?? '',
          proposals: proposals,
        );

      // Back-compat with the original single-entry actions.
      case 'propose_create':
      case 'propose_update':
        final e = json['entry'];
        if (e is! Map<String, Object?>) {
          return SeedingAction(
            kind: SeedingActionKind.chat,
            message: json['message'] as String? ?? raw.trim(),
          );
        }
        return SeedingAction(
          kind: SeedingActionKind.propose,
          proposals: [
            _proposal(e, wiki, forceUpdate: action == 'propose_update'),
          ],
        );

      default:
        return SeedingAction(
          kind: SeedingActionKind.chat,
          message: json['message'] as String? ?? raw.trim(),
        );
    }
  }

  SeedingProposal _proposal(
    Map<String, Object?> e,
    Map<String, WikiEntry> wiki, {
    bool? forceUpdate,
  }) {
    final title = e['title'] as String? ?? '';
    final id = e['id'] as String? ??
        'wiki-${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';
    // An entry is an update if the model says so, or if its id already exists.
    final isUpdate =
        forceUpdate ?? (e['op'] == 'update' || wiki.containsKey(id));
    final base = isUpdate ? wiki[id] : null;
    return SeedingProposal(
      isUpdate: isUpdate,
      entry: WikiEntry(
        id: id,
        worldId: worldId,
        title: title.isEmpty ? (base?.title ?? '') : title,
        category: e['category'] as String? ?? base?.category ?? '',
        body: e['body'] as String? ?? base?.body ?? '',
        tags: [
          for (final t in e['tags'] as List<Object?>? ?? <Object?>[])
            if (t != null) '$t'
        ],
        clockRef: (e['clock_ref'] as num?)?.round() ?? base?.clockRef,
        version: base?.version ?? 1,
      ),
    );
  }

  /// Commit one proposal as an event (change-log write-through, §5.1).
  Future<Event> accept(SeedingProposal proposal) {
    final cause = {'seeding_transcript_tail': transcript.length};
    return proposal.isUpdate
        ? service.updateWikiEntry(proposal.entry, cause: cause)
        : service.createWikiEntry(proposal.entry, cause: cause);
  }
}
