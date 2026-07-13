/// Living Worlds deterministic engine.
///
/// Design principle: **the LLM proposes, the deterministic engine disposes.**
/// The world is an append-only event log; everything else is a projection.
library;

export 'src/context/assembler.dart';
export 'src/context/summarizer.dart';
export 'src/cost/cost_log.dart';
export 'src/debug/report.dart';
export 'src/engine/character_generator.dart';
export 'src/engine/config.dart';
export 'src/engine/death.dart';
export 'src/engine/health.dart';
export 'src/engine/rendezvous.dart';
export 'src/engine/time_skip.dart';
export 'src/engine/turn_controller.dart';
export 'src/engine/turn_engine.dart';
export 'src/engine/validation.dart';
export 'src/engine/world_service.dart';
export 'src/image/image_client.dart';
export 'src/llm/contract.dart';
export 'src/llm/llm_client.dart';
export 'src/llm/openrouter_client.dart';
export 'src/model/character.dart';
export 'src/model/event.dart';
export 'src/model/item.dart';
export 'src/model/quest.dart';
export 'src/model/relationship.dart';
export 'src/model/wiki.dart';
export 'src/model/world.dart';
export 'src/model/world_schema.dart';
export 'src/projection/projection.dart';
export 'src/repo/in_memory_repository.dart';
export 'src/repo/local_repository.dart';
export 'src/repo/remote_repository.dart';
export 'src/repo/world_repository.dart';
export 'src/retrieval/cosine.dart';
export 'src/retrieval/embedding_client.dart';
export 'src/save/save_codec.dart';
export 'src/util/rng.dart';
export 'src/wiki/seeding_session.dart';
