/// Seeding UI (§12, §5.1): ChatGPT-style workshop bound to wiki CRUD with a
/// clarifying-question flow and change-log write-through. Conversations are
/// persisted as per-world threads so they survive navigation and restarts.
/// A single model response may propose several entries, each committed
/// independently; a committed proposal's button deactivates.
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../persistence.dart';
import '../world_store.dart';

class SeedingScreen extends StatefulWidget {
  const SeedingScreen({super.key, required this.store, required this.thread});

  final WorldStore store;
  final SeedingThread thread;

  @override
  State<SeedingScreen> createState() => _SeedingScreenState();
}

class _SeedingScreenState extends State<SeedingScreen> {
  late final SeedingSession _session = widget.store.newSeedingSession(
    resume: widget.thread,
  );
  final _input = TextEditingController();
  bool _busy = false;

  /// Proposals attached to a given message index (a proposal-header message),
  /// kept in memory for the current session so each can be accepted.
  final Map<int, List<SeedingProposal>> _proposals = {};

  /// `msgIndex:propIndex` of proposals already committed.
  final Set<String> _committed = {};

  SeedingThread get thread => widget.thread;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    thread.updatedAt = DateTime.now();
    final firstUser = thread.messages.where((m) => m.fromUser).firstOrNull;
    if (firstUser != null && thread.title == 'New workshop thread') {
      thread.title = firstUser.text.length <= 40
          ? firstUser.text
          : '${firstUser.text.substring(0, 37)}...';
    }
    await widget.store.persistSeedingThreads();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      thread.messages.add(SeedingMessage(fromUser: true, text: text));
      _busy = true;
    });
    await _persist();
    try {
      final action = await _session.send(text);
      setState(() {
        switch (action.kind) {
          case SeedingActionKind.clarify:
          case SeedingActionKind.chat:
            thread.messages.add(
              SeedingMessage(
                fromUser: false,
                text: action.message.isEmpty ? '(no reply)' : action.message,
              ),
            );
          case SeedingActionKind.propose:
            final header = action.message.isNotEmpty
                ? action.message
                : (action.proposals.length == 1
                      ? 'Proposed an entry:'
                      : 'Proposed ${action.proposals.length} entries:');
            thread.messages.add(SeedingMessage(fromUser: false, text: header));
            _proposals[thread.messages.length - 1] = action.proposals;
        }
      });
      await _persist();
    } catch (e) {
      setState(
        () => thread.messages.add(
          SeedingMessage(fromUser: false, text: 'Error: $e'),
        ),
      );
      await _persist();
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _accept(int msgIndex, int propIndex, SeedingProposal p) async {
    setState(() => _busy = true);
    try {
      await _session.accept(p);
      await widget.store.refresh();
      setState(() {
        _committed.add('$msgIndex:$propIndex');
        thread.messages.add(
          SeedingMessage(
            fromUser: false,
            text:
                'Committed "${p.entry.title}" to the wiki '
                '(event logged; undo in the change log).',
          ),
        );
      });
      await _persist();
    } catch (e) {
      setState(
        () => thread.messages.add(
          SeedingMessage(fromUser: false, text: 'Error: $e'),
        ),
      );
      await _persist();
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(thread.title)),
      body: Column(
        children: [
          Expanded(
            // SelectionArea makes every message selectable/copyable.
            child: SelectionArea(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Behind-the-scenes world building: describe people, '
                        'places, factions, lore. The assistant may ask '
                        'clarifying questions, then proposes wiki entries you '
                        'approve. It can propose several at once — accept each '
                        'separately. No clock, no dice, no character state '
                        '(§5.1).',
                      ),
                    ),
                  ),
                  for (var i = 0; i < thread.messages.length; i++)
                    _bubble(context, i, thread.messages[i]),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 10),
                          Text('Thinking…'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('seeding-input'),
                      controller: _input,
                      // Multi-line: Return inserts a newline; send via button.
                      minLines: 1,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Describe something for the wiki…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('seeding-send'),
                    icon: const Icon(Icons.send),
                    onPressed: _busy ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, int index, SeedingMessage m) {
    final proposals = _proposals[index] ?? const <SeedingProposal>[];
    return Column(
      crossAxisAlignment: m.fromUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Card(
            color: m.fromUser
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(m.text),
            ),
          ),
        ),
        for (var p = 0; p < proposals.length; p++)
          _proposalCard(context, index, p, proposals[p]),
      ],
    );
  }

  Widget _proposalCard(
    BuildContext context,
    int msgIndex,
    int propIndex,
    SeedingProposal proposal,
  ) {
    final committed = _committed.contains('$msgIndex:$propIndex');
    final e = proposal.entry;
    return Card(
      key: Key('proposal-$msgIndex-$propIndex'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${e.title} · ${e.category}'
              '${proposal.isUpdate ? '  (update)' : ''}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(e.body),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: Key('accept-proposal-$msgIndex-$propIndex'),
                onPressed: (_busy || committed)
                    ? null
                    : () => _accept(msgIndex, propIndex, proposal),
                icon: Icon(committed ? Icons.check : Icons.save),
                label: Text(committed ? 'Committed' : 'Accept & commit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
