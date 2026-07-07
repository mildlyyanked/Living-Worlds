/// Dependency seams for the app. Everything the UI touches goes through
/// [AppServices], so widget tests can swap in in-memory repositories and the
/// FixtureLlmClient — same philosophy as the engine (§11).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';
import 'package:path_provider/path_provider.dart';

import 'persistence.dart';

/// Where completions come from (§7 key handling).
enum LlmMode {
  /// No network: a scripted narrator so the loop is playable/testable.
  offline,

  /// Dev-only direct OpenRouter key (guarded behind settings, §7).
  openRouterDirect,

  /// Production path: Supabase Edge Function key vault.
  supabaseProxy,
}

/// User settings, persisted to a [KeyValueStore] so the OpenRouter key and
/// other choices survive app restarts.
class AppSettings extends ChangeNotifier {
  AppSettings(this._kv);

  final KeyValueStore _kv;
  static const _storeKey = 'app_settings';

  LlmMode llmMode = LlmMode.offline;
  String openRouterKey = '';
  String supabaseUrl = '';
  String supabaseAnonKey = '';
  String model = 'anthropic/claude-sonnet-4.5';
  bool debugPanel = false;
  int contextBudgetTokens = 6000;

  /// Read persisted values (call once at startup).
  Future<void> load() async {
    final raw = await _kv.get(_storeKey);
    if (raw == null || raw.isEmpty) return;
    final j = jsonDecode(raw) as Map<String, Object?>;
    llmMode = LlmMode.values.firstWhere(
      (m) => m.name == j['llmMode'],
      orElse: () => llmMode,
    );
    openRouterKey = j['openRouterKey'] as String? ?? openRouterKey;
    supabaseUrl = j['supabaseUrl'] as String? ?? supabaseUrl;
    supabaseAnonKey = j['supabaseAnonKey'] as String? ?? supabaseAnonKey;
    model = j['model'] as String? ?? model;
    debugPanel = j['debugPanel'] as bool? ?? debugPanel;
    contextBudgetTokens =
        (j['contextBudgetTokens'] as num?)?.round() ?? contextBudgetTokens;
    notifyListeners();
  }

  void update(void Function(AppSettings s) fn) {
    fn(this);
    notifyListeners();
    // Fire-and-forget persist; the next load() reflects it.
    _save();
  }

  Future<void> _save() => _kv.set(
    _storeKey,
    jsonEncode({
      'llmMode': llmMode.name,
      'openRouterKey': openRouterKey,
      'supabaseUrl': supabaseUrl,
      'supabaseAnonKey': supabaseAnonKey,
      'model': model,
      'debugPanel': debugPanel,
      'contextBudgetTokens': contextBudgetTokens,
    }),
  );
}

/// A known world: where its event log lives + display info.
class WorldRef {
  const WorldRef({required this.id, required this.name, required this.path});

  final String id;
  final String name;

  /// SQLite file path, or 'memory' for test worlds.
  final String path;
}

class AppServices {
  AppServices({
    WorldRepository Function(String path)? repoFactory,
    LlmClient Function(AppSettings settings)? llmFactory,
    EmbeddingClient Function(AppSettings settings)? embedderFactory,
    Future<Directory> Function()? worldsDirProvider,
    KeyValueStore? keyValueStore,
    this.scanDiskWorlds = true,
  }) : kv = keyValueStore ?? SharedPrefsKeyValueStore(),
       _repoFactory = repoFactory ?? _defaultRepoFactory,
       _llmFactory = llmFactory ?? _defaultLlmFactory,
       _embedderFactory = embedderFactory ?? ((_) => FixtureEmbeddingClient()),
       _worldsDir = worldsDirProvider ?? _defaultWorldsDir;

  /// Widget tests run in a fake-async zone where real disk IO never
  /// completes; they set this false and use in-memory worlds only.
  final bool scanDiskWorlds;

  final KeyValueStore kv;
  late final AppSettings settings = AppSettings(kv);
  late final SeedingThreadStore seedingThreads = SeedingThreadStore(kv);
  final WorldRepository Function(String path) _repoFactory;
  final LlmClient Function(AppSettings settings) _llmFactory;
  final EmbeddingClient Function(AppSettings settings) _embedderFactory;
  final Future<Directory> Function() _worldsDir;

  final Map<String, WorldRepository> _open = {};

  /// One-time startup: load persisted settings.
  Future<void> init() => settings.load();

  static WorldRepository _defaultRepoFactory(String path) =>
      path == 'memory' ? InMemoryRepository() : LocalRepository.open(path);

  static Future<Directory> _defaultWorldsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/living_worlds');
    await dir.create(recursive: true);
    return dir;
  }

  static LlmClient _defaultLlmFactory(AppSettings s) => switch (s.llmMode) {
    LlmMode.offline => OfflineNarratorLlm(),
    LlmMode.openRouterDirect => OpenRouterLlmClient(
      baseUrl: 'https://openrouter.ai/api/v1',
      apiKey: s.openRouterKey,
      model: s.model,
    ),
    LlmMode.supabaseProxy => OpenRouterLlmClient(
      baseUrl: '${s.supabaseUrl}/functions/v1/llm-proxy',
      apiKey: s.supabaseAnonKey,
      model: s.model,
    ),
  };

  LlmClient buildLlm() => _llmFactory(settings);
  EmbeddingClient buildEmbedder() => _embedderFactory(settings);

  Future<WorldRepository> openRepo(WorldRef ref) async =>
      _open[ref.id] ??= _repoFactory(ref.path);

  Future<List<WorldRef>> listWorlds() async {
    final refs = <WorldRef>[];
    // Already-open worlds (including in-memory test worlds) surface first.
    for (final entry in _open.entries) {
      final p = await entry.value.projection();
      if (p.world != null) {
        refs.add(
          WorldRef(id: p.world!.id, name: p.world!.name, path: 'memory'),
        );
      }
    }
    if (scanDiskWorlds) {
      final dir = await _worldsDir();
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.db')) continue;
        final repo = _repoFactory(f.path);
        try {
          final p = await repo.projection();
          if (p.world != null && !refs.any((r) => r.id == p.world!.id)) {
            refs.add(
              WorldRef(id: p.world!.id, name: p.world!.name, path: f.path),
            );
          }
        } finally {
          await repo.close();
        }
      }
    }
    refs.sort((a, b) => a.name.compareTo(b.name));
    return refs;
  }

  /// Create a new playable world with the standard schema, a starter
  /// character, and starter item definitions.
  Future<WorldRef> createWorld({
    required String name,
    required String characterName,
    int? seed,
    bool inMemory = false,
  }) async {
    final id = 'world-${DateTime.now().millisecondsSinceEpoch}';
    final path = inMemory ? 'memory' : '${(await _worldsDir()).path}/$id.db';
    final repo = _repoFactory(path);
    _open[id] = repo;

    final service = WorldService(repo);
    await service.createWorld(
      World(
        id: id,
        name: name,
        seed: seed ?? DateTime.now().millisecondsSinceEpoch & 0xFFFFFF,
        createdAt: DateTime.now().toUtc(),
        schema: WorldSchema.standard(),
      ),
    );
    final charId = characterName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '-',
    );
    await service.createCharacter(
      Character(
        id: charId,
        worldId: id,
        name: characterName,
        bio: 'A newcomer to $name.',
        stats: const {'vitality': 100, 'hunger': 0, 'fatigue': 0, 'coin': 10},
      ),
    );
    for (final def in _starterItems(id)) {
      await service.createItemDef(def);
    }
    return WorldRef(id: id, name: name, path: path);
  }

  static List<ItemDef> _starterItems(String worldId) => [
    ItemDef(
      id: 'item-rusty-key',
      worldId: worldId,
      name: 'rusty key',
      desc: 'Opens something old.',
      affordances: const ['unlock'],
      stackable: false,
    ),
    ItemDef(
      id: 'item-potion',
      worldId: worldId,
      name: 'healing potion',
      desc: 'Staunches wounds and lifts fatigue.',
      affordances: const ['heal'],
      effects: const [
        ItemEffect(onUse: 'heal', statusKey: 'bleeding', statusOp: 'remove'),
        ItemEffect(onUse: 'heal', statKey: 'fatigue', statDelta: -20),
      ],
      consumable: true,
    ),
    ItemDef(
      id: 'item-lantern',
      worldId: worldId,
      name: 'storm lantern',
      desc: 'Light in dark places.',
      affordances: const ['light'],
    ),
  ];
}

/// Offline narrator: deterministic canned improv so the whole app is usable
/// (and widget-testable) without any network or key.
class OfflineNarratorLlm implements LlmClient {
  int _n = 0;

  @override
  Future<LlmTurnResult> completeTurn({
    required String systemPrompt,
    required String context,
    required String userInput,
    required LlmToolHandler tools,
  }) async {
    _n++;
    final output = TurnOutput(
      narrative:
          'You $userInput. The world holds its breath, then lets it '
          'out; nothing bites you today. (offline narrator, turn $_n)',
      proposedDeltas: const ProposedDeltas(clockAdvanceMinutes: 30),
    );
    return LlmTurnResult(
      output: output,
      usage: const LlmUsage(model: 'offline', cached: true),
      rawJson: null,
    );
  }

  @override
  Future<String> complete({
    required String systemPrompt,
    required String prompt,
    bool expectJson = false,
  }) async {
    if (expectJson) {
      return '{"summary": "Quiet days pass.", "proposed_deltas": {}}';
    }
    return 'Quiet days pass.';
  }
}

/// Inherited access to [AppServices].
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
