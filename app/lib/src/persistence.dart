/// App-local persistence seam. Settings and seeding-workshop threads are UI
/// scaffolding, not canonical world state, so they live here (key/value)
/// rather than in the engine's event log. The seam is injectable so widget
/// tests use an in-memory store and never touch the platform plugin.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

/// Production store backed by shared_preferences.
class SharedPrefsKeyValueStore implements KeyValueStore {
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<String?> get(String key) async => (await _p).getString(key);

  @override
  Future<void> set(String key, String value) async =>
      (await _p).setString(key, value);

  @override
  Future<void> remove(String key) async => (await _p).remove(key);
}

/// Hermetic store for tests.
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, String>? seed]) : _m = {...?seed};

  final Map<String, String> _m;

  @override
  Future<String?> get(String key) async => _m[key];

  @override
  Future<void> set(String key, String value) async => _m[key] = value;

  @override
  Future<void> remove(String key) async => _m.remove(key);
}

/// On-device store for generated image bytes (§ images). Serverless: images
/// live as files on the device, keyed by world + image id, and are referenced
/// from wiki entries by id (keeping the event log lean). Injectable so widget
/// tests use an in-memory variant and never touch the filesystem.
abstract class ImageStore {
  Future<void> save(String worldId, String imageId, Uint8List bytes);
  Future<Uint8List?> load(String worldId, String imageId);
}

/// Production store: files under `<docs>/living_worlds/images/<world>/<id>`.
class FileImageStore implements ImageStore {
  Future<Directory> _dir(String worldId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/living_worlds/images/$worldId');
    await dir.create(recursive: true);
    return dir;
  }

  String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  @override
  Future<void> save(String worldId, String imageId, Uint8List bytes) async {
    final f = File('${(await _dir(worldId)).path}/${_safe(imageId)}');
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> load(String worldId, String imageId) async {
    final f = File('${(await _dir(worldId)).path}/${_safe(imageId)}');
    return f.existsSync() ? f.readAsBytes() : null;
  }
}

/// Hermetic store for tests.
class InMemoryImageStore implements ImageStore {
  final Map<String, Uint8List> _m = {};

  @override
  Future<void> save(String worldId, String imageId, Uint8List bytes) async =>
      _m['$worldId/$imageId'] = bytes;

  @override
  Future<Uint8List?> load(String worldId, String imageId) async =>
      _m['$worldId/$imageId'];
}

/// One line in a seeding-workshop conversation.
class SeedingMessage {
  SeedingMessage({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;

  Map<String, Object?> toJson() => {'fromUser': fromUser, 'text': text};

  factory SeedingMessage.fromJson(Map<String, Object?> j) => SeedingMessage(
    fromUser: j['fromUser'] as bool? ?? false,
    text: j['text'] as String? ?? '',
  );
}

/// A persisted seeding-workshop conversation thread (§5.1). Kept per-world so
/// the workshop history survives navigation and app restarts.
class SeedingThread {
  SeedingThread({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    List<SeedingMessage>? messages,
  }) : messages = messages ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<SeedingMessage> messages;

  factory SeedingThread.fresh() {
    final now = DateTime.now();
    return SeedingThread(
      id: 'thread-${now.microsecondsSinceEpoch}',
      title: 'New workshop thread',
      createdAt: now,
      updatedAt: now,
    );
  }

  /// A short preview for the thread list.
  String get preview => messages.isEmpty
      ? 'Empty — tap to start.'
      : messages.last.text.replaceAll('\n', ' ');

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
  };

  factory SeedingThread.fromJson(Map<String, Object?> j) => SeedingThread(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'Workshop thread',
    createdAt:
        DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
    messages: [
      for (final m in j['messages'] as List<Object?>? ?? <Object?>[])
        SeedingMessage.fromJson(m! as Map<String, Object?>),
    ],
  );
}

/// Loads/saves the seeding threads for a world, newest first.
class SeedingThreadStore {
  SeedingThreadStore(this.kv);

  final KeyValueStore kv;

  String _key(String worldId) => 'seeding_threads_$worldId';

  Future<List<SeedingThread>> load(String worldId) async {
    final raw = await kv.get(_key(worldId));
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<Object?>;
    final threads = [
      for (final t in list) SeedingThread.fromJson(t! as Map<String, Object?>),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return threads;
  }

  Future<void> save(String worldId, List<SeedingThread> threads) =>
      kv.set(_key(worldId), jsonEncode([for (final t in threads) t.toJson()]));
}
