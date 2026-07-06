/// Wiki tab (§12): content viewer, change log with undo/redo, seeding
/// session window, candidate review queue.
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../screens/seeding_screen.dart';
import '../world_store.dart';

class WikiTab extends StatefulWidget {
  const WikiTab({super.key, required this.store});

  final WorldStore store;

  @override
  State<WikiTab> createState() => _WikiTabState();
}

class _WikiTabState extends State<WikiTab> {
  WorldStore get store => widget.store;

  @override
  Widget build(BuildContext context) {
    final p = store.projection!;
    final entries = p.wiki.values.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    final candidates = p.pendingCandidates.values.toList();

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (candidates.isNotEmpty) ...[
            Text(
              'Review queue (from gameplay, §5.2)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final c in candidates)
              Card(
                key: Key('candidate-${c.id}'),
                child: ListTile(
                  title: Text('${c.title}  ·  ${c.category}'),
                  subtitle: Text(
                    c.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('promote-${c.id}'),
                        icon: const Icon(Icons.check, color: Colors.green),
                        tooltip: 'Promote to wiki',
                        onPressed: () => _promote(c),
                      ),
                      IconButton(
                        key: Key('reject-${c.id}'),
                        icon: const Icon(Icons.close, color: Colors.red),
                        tooltip: 'Reject',
                        onPressed: () => store.rejectCandidate(c),
                      ),
                    ],
                  ),
                ),
              ),
            const Divider(),
          ],
          Text('Entries', style: Theme.of(context).textTheme.titleMedium),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Nothing written yet — open the seeding workshop '
                'to build the world.',
              ),
            ),
          for (final w in entries)
            Card(
              key: Key('wiki-${w.id}'),
              child: ListTile(
                title: Text('${w.title}  ·  ${w.category}  ·  v${w.version}'),
                subtitle: Text(
                  w.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _view(w),
              ),
            ),
          const Divider(),
          _ChangeLog(store: store),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('open-seeding'),
        icon: const Icon(Icons.auto_fix_high),
        label: const Text('Seeding workshop'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => SeedingScreen(store: store)),
        ),
      ),
    );
  }

  void _view(WikiEntry w) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(w.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${w.category} · v${w.version}'
                '${w.clockRef != null ? ' · timeline @${w.clockRef}min' : ''}'
                '${w.tags.isNotEmpty ? '\ntags: ${w.tags.join(', ')}' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(w.body),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _promote(WikiCandidate c) async {
    final id =
        'wiki-${c.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}';
    await store.promoteCandidate(
      c,
      WikiEntry(
        id: id,
        worldId: store.ref.id,
        title: c.title,
        category: c.category,
        body: c.body,
        tags: c.tags,
        clockRef: c.clockRef,
      ),
    );
  }
}

/// The wiki change log IS the event log filtered to wiki events — with
/// undo/redo directly on it (§1.1, §5.1).
class _ChangeLog extends StatelessWidget {
  const _ChangeLog({required this.store});

  final WorldStore store;

  static const _wikiTypes = {
    EventType.wikiCreated,
    EventType.wikiUpdated,
    EventType.wikiCandidateQueued,
    EventType.wikiCandidatePromoted,
    EventType.wikiCandidateRejected,
  };

  Future<(List<Event>, Set<int>)> _load() async =>
      (await store.repo.eventsUpTo(-1), await store.repo.revertedSeqs());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(List<Event>, Set<int>)>(
      future: _load(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        final (events, reverted) = snap.data!;
        final wikiEvents = events
            .where((e) => _wikiTypes.contains(e.type))
            .toList()
            .reversed
            .toList();
        if (wikiEvents.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Change log', style: Theme.of(context).textTheme.titleMedium),
            for (final e in wikiEvents)
              ListTile(
                key: Key('changelog-${e.seq}'),
                dense: true,
                leading: Text('#${e.seq}'),
                title: Text(
                  _describe(e),
                  style: reverted.contains(e.seq)
                      ? const TextStyle(decoration: TextDecoration.lineThrough)
                      : null,
                ),
                trailing: reverted.contains(e.seq)
                    ? TextButton(
                        key: Key('redo-${e.seq}'),
                        onPressed: () => store.redoToSeq(e.seq),
                        child: const Text('Redo'),
                      )
                    : TextButton(
                        key: Key('undo-${e.seq}'),
                        onPressed: () => store.undoToSeq(e.seq - 1),
                        child: const Text('Undo to here'),
                      ),
              ),
          ],
        );
      },
    );
  }

  String _describe(Event e) {
    final entry = e.payload['entry'] as Map<String, Object?>?;
    final title = entry?['title'] ?? e.payload['candidate_id'] ?? '';
    return switch (e.type) {
      EventType.wikiCreated => 'Created "$title"',
      EventType.wikiUpdated =>
        'Updated "$title" (v${e.payload['from_version']} → '
            'v${(entry?['version'])})',
      EventType.wikiCandidateQueued => 'Queued candidate from gameplay',
      EventType.wikiCandidatePromoted => 'Promoted candidate → "$title"',
      EventType.wikiCandidateRejected => 'Rejected candidate',
      _ => e.type.name,
    };
  }
}
