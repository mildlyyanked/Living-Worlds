/// Per-world state holder: wraps the engine's TurnController and services,
/// exposes actions the UI calls, notifies on every committed change.
library;

import 'package:flutter/foundation.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import 'app_services.dart';
import 'persistence.dart';

/// One rendered chat item in the gameplay window.
class ChatItem {
  const ChatItem({
    required this.userInput,
    required this.narrative,
    required this.notifications,
    required this.report,
    required this.turnSeq,
    this.died = false,
    this.observation = false,
  });

  final String userInput;
  final String narrative;
  final List<String> notifications;
  final TurnDebugReport? report;
  final int turnSeq;
  final bool died;

  /// A non-consequential observation (no clock, no deltas).
  final bool observation;
}

class WorldStore extends ChangeNotifier {
  WorldStore({required this.services, required this.ref, required this.repo});

  final AppServices services;
  final WorldRef ref;
  final WorldRepository repo;

  WorldProjection? projection;
  final CostLog costLog = CostLog();
  bool busy = false;
  String? lastError;

  /// Seeding-workshop threads for this world (newest first), persisted
  /// per-world so the conversation survives navigation and restarts.
  List<SeedingThread> seedingThreads = [];

  static Future<WorldStore> open(AppServices services, WorldRef ref) async {
    final store = WorldStore(
      services: services,
      ref: ref,
      repo: await services.openRepo(ref),
    );
    await store.refresh();
    store.seedingThreads = await services.seedingThreads.load(ref.id);
    return store;
  }

  Future<void> persistSeedingThreads() async {
    seedingThreads.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await services.seedingThreads.save(ref.id, seedingThreads);
    notifyListeners();
  }

  SeedingThread startSeedingThread() {
    final thread = SeedingThread.fresh();
    seedingThreads.insert(0, thread);
    persistSeedingThreads();
    return thread;
  }

  Future<void> deleteSeedingThread(SeedingThread thread) async {
    seedingThreads.removeWhere((t) => t.id == thread.id);
    await persistSeedingThreads();
  }

  TurnController _controller() => TurnController(
    repo: repo,
    llm: services.buildLlm(),
    embedder: services.buildEmbedder(),
    assembler: ContextAssembler(
      budgetTokens: services.settings.contextBudgetTokens,
    ),
    costLog: costLog,
  );

  WorldService get worldService => WorldService(repo);

  Future<void> refresh() async {
    projection = await repo.projection();
    notifyListeners();
  }

  Future<T?> _guard<T>(Future<T> Function() action) async {
    busy = true;
    lastError = null;
    notifyListeners();
    try {
      return await action();
    } catch (e) {
      lastError = '$e';
      return null;
    } finally {
      busy = false;
      await refresh();
    }
  }

  /// Chat history for a character, rebuilt from the log (source of truth).
  List<ChatItem> chatFor(String characterId) {
    final p = projection;
    if (p == null) return const [];
    final items = <ChatItem>[];
    for (final t in p.turnsFor(characterId)) {
      items.add(
        ChatItem(
          userInput: t.userInput,
          narrative: t.narrative,
          notifications: const [],
          report: null,
          turnSeq: t.seq,
          observation: t.observation,
        ),
      );
    }
    return items;
  }

  /// Debug report for a committed turn, straight from the event log (§9).
  Future<TurnDebugReport?> reportFor(int turnSeq) async {
    final events = await repo.eventsUpTo(turnSeq);
    for (final e in events.reversed) {
      if (e.seq == turnSeq && e.type == EventType.turnCommitted) {
        final raw = e.cause['debug_report'];
        if (raw is Map<String, Object?>) return TurnDebugReport.fromJson(raw);
      }
    }
    return null;
  }

  Future<CommittedTurn?> playTurn({
    required String actorId,
    required String input,
    List<String> presentCharacterIds = const [],
    bool observe = false,
  }) => _guard(
    () => _controller().playTurn(
      actorId: actorId,
      userInput: input,
      presentCharacterIds: presentCharacterIds,
      observe: observe,
    ),
  );

  /// Generate a character from a seeding paragraph, then create it starting at
  /// the current world clock, with a structured bio, opening scenario and any
  /// background quest (§ onboarding).
  Future<Character?> createSeededCharacter({
    required String name,
    required String seedParagraph,
  }) => _guard(() async {
    final p = projection!;
    final schema = p.world!.schema;
    final id = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final generated = await CharacterGenerator(llm: services.buildLlm())
        .generate(
          name: name,
          seedParagraph: seedParagraph,
          worldName: ref.name,
          worldBio: p.worldBioText(),
        );
    final character = Character(
      id: id,
      worldId: ref.id,
      name: name,
      bio: generated.bio,
      openingScenario: generated.openingScenario,
      subjectiveClock: p.worldClock,
      stats: {for (final d in schema.statDefs) d.key: d.defaultValue},
      quests: [if (generated.startingQuest != null) generated.startingQuest!],
    );
    await worldService.createCharacter(character);
    return character;
  });

  Future<void> designateWorldBio(String? entryId) async {
    await _guard(() => worldService.designateWorldBio(ref.id, entryId));
  }

  Future<TimeSkipResult?> timeSkip({
    required String characterId,
    required TimeSkipTarget target,
  }) => _guard(
    () => TimeSkipGenerator(
      repo,
    ).run(characterId: characterId, target: target, llm: services.buildLlm()),
  );

  Future<void> undoToSeq(int seq) async {
    await _guard(() => repo.revertAfter(seq));
  }

  Future<void> redoToSeq(int seq) async {
    await _guard(() => repo.unrevertUpTo(seq));
  }

  Future<Event?> promoteCandidate(WikiCandidate cand, WikiEntry entry) =>
      _guard(() => worldService.promoteCandidate(cand.id, entry));

  Future<Event?> rejectCandidate(WikiCandidate cand) =>
      _guard(() => worldService.rejectCandidate(ref.id, cand.id));

  Future<String?> exportSave() =>
      _guard(() => const SaveCodec().exportWorld(repo));

  Future<void> saveToSlot(String slot) async {
    await _guard(() async {
      final blob = await const SaveCodec().exportWorld(repo);
      await repo.saveWorldSnapshot(slot, blob);
    });
  }

  /// Seeding session bound to this world (§5.1). When [resume] is given, its
  /// prior messages pre-seed the session transcript so the model keeps the
  /// conversation's context on continuation.
  SeedingSession newSeedingSession({SeedingThread? resume}) {
    final session = SeedingSession(
      repo: repo,
      llm: services.buildLlm(),
      worldId: ref.id,
    );
    if (resume != null) {
      for (final m in resume.messages) {
        session.transcript.add((
          role: m.fromUser ? 'user' : 'assistant',
          text: m.text,
        ));
      }
    }
    return session;
  }
}
