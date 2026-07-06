/// Save / Load tab (§8, §12): slots backed by the repository's snapshot
/// store (SQLite locally, Supabase Storage remotely). A save is the full
/// event log — inherently consistent, diff-able JSON.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../world_store.dart';

class SaveLoadTab extends StatefulWidget {
  const SaveLoadTab({super.key, required this.store});

  final WorldStore store;

  @override
  State<SaveLoadTab> createState() => _SaveLoadTabState();
}

class _SaveLoadTabState extends State<SaveLoadTab> {
  static const slots = ['slot-1', 'slot-2', 'slot-3'];
  String? _status;

  WorldStore get store => widget.store;

  Future<void> _save(String slot) async {
    await store.saveToSlot(slot);
    setState(() => _status = store.lastError == null
        ? 'Saved to $slot.'
        : 'Save failed: ${store.lastError}');
  }

  Future<void> _copyExport() async {
    final blob = await store.exportSave();
    if (blob != null) {
      await Clipboard.setData(ClipboardData(text: blob));
      setState(() => _status =
          'Export copied to clipboard (${(blob.length / 1024).toStringAsFixed(1)} KB of JSON).');
    }
  }

  Future<void> _inspect(String slot) async {
    String text;
    try {
      final blob = await store.repo.loadWorldSnapshot(slot);
      final save = const SaveCodec().decode(blob);
      text = 'Format v${save.formatVersion} · ${save.events.length} events · '
          '${save.revertedSeqs.length} revert markers.\n\n'
          'Loading a save restores the full event log and rebuilds all '
          'projections, verified against the cached projection (§8).';
    } on WorldRepositoryException catch (e) {
      text = '$e';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(slot),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = store.projection!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'World "${p.world?.name}" · ${p.lastSeq + 1} events · '
              'seed ${p.world?.seed}\n'
              'A save is the append-only event log itself: text JSON, '
              'diff-able, replayable.',
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final slot in slots)
          Card(
            child: ListTile(
              key: Key('save-$slot'),
              leading: const Icon(Icons.save),
              title: Text(slot),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: Key('save-btn-$slot'),
                    onPressed: () => _save(slot),
                    child: const Text('Save'),
                  ),
                  TextButton(
                    key: Key('inspect-btn-$slot'),
                    onPressed: () => _inspect(slot),
                    child: const Text('Inspect'),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('export-clipboard'),
          onPressed: _copyExport,
          icon: const Icon(Icons.copy_all),
          label: const Text('Export world JSON to clipboard'),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_status!, key: const Key('save-status')),
          ),
      ],
    );
  }
}
