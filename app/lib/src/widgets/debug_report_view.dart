/// Debug panel (§9): bubbles up the whole turn transaction — raw LLM output
/// pre-validation, per-delta decisions, tool calls, death eval, context
/// section token counts, usage/cost.
library;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../world_store.dart';

class DebugPanel extends StatelessWidget {
  const DebugPanel({super.key, required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final report = item.report;
    return Material(
      key: const Key('debug-panel'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: report == null
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No debug report for this turn '
                  '(loaded from history — open via event log).',
                ),
              )
            : DebugReportView(report: report),
      ),
    );
  }
}

class DebugReportView extends StatelessWidget {
  const DebugReportView({super.key, required this.report});

  final TurnDebugReport report;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final eval = report.deathEval;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('TURN DEBUG (§9)', style: Theme.of(context).textTheme.labelLarge),
        if (eval != null)
          Text(
            'death eval: health=${eval.health.toStringAsFixed(1)} '
            'P=${eval.probability.toStringAsFixed(4)} '
            'seed=${eval.seedTurn} draw=${eval.draw.toStringAsFixed(4)} '
            '=> ${eval.outcome ? "DEAD" : "alive"}'
            '${eval.instantTrigger != null ? " instant:${eval.instantTrigger}" : ""}'
            '${eval.skippedNonLethal ? " (non-lethal skip)" : ""} '
            '[peril: engine=${eval.perilDeltaApplied} llm=${eval.perilHint}]',
            style: mono,
            key: const Key('debug-death-eval'),
          ),
        const SizedBox(height: 6),
        Text('deltas:', style: Theme.of(context).textTheme.labelMedium),
        for (final d in report.decisions)
          Text(
            '  [${d.section}] ${d.outcome.name}'
            '${d.outcome == DeltaOutcome.clamped ? " ${d.from} -> ${d.to}" : ""}'
            '${d.reason.isNotEmpty ? " — ${d.reason}" : ""}',
            style: mono?.copyWith(
              color: switch (d.outcome) {
                DeltaOutcome.accepted => Colors.greenAccent,
                DeltaOutcome.clamped => Colors.orangeAccent,
                DeltaOutcome.rejected => Colors.redAccent,
              },
            ),
          ),
        if (report.toolExchanges.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('tool calls:', style: Theme.of(context).textTheme.labelMedium),
          for (final t in report.toolExchanges)
            Text(
              '  ${t.call.name}(${t.call.args}) -> ${t.result}',
              style: mono,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
        const SizedBox(height: 6),
        Text(
          'context sections:',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        for (final s in report.contextSections)
          Text(
            '  ${s.section}: ${s.tokens} tok'
            '${s.included ? "" : " (DROPPED)"}'
            '${s.detail.isNotEmpty ? " — ${s.detail}" : ""}',
            style: mono,
          ),
        const SizedBox(height: 6),
        Text(
          'usage: ${report.usage.model} '
          '${report.usage.promptTokens}+${report.usage.completionTokens} tok '
          '\$${report.usage.computedCostUsd.toStringAsFixed(4)} '
          '${report.usage.latencyMs} ms'
          '${report.usage.cached ? " (cached)" : ""}',
          style: mono,
        ),
        if (report.notes.isNotEmpty)
          Text('notes: ${report.notes.join("; ")}', style: mono),
        if (report.contextText != null && report.contextText!.isNotEmpty) ...[
          const SizedBox(height: 6),
          ExpansionTile(
            key: const Key('debug-context'),
            title: const Text('context sent (phase 1)'),
            tilePadding: EdgeInsets.zero,
            children: [Text(report.contextText!, style: mono)],
          ),
        ],
        if (report.rawLlmJson != null) ...[
          ExpansionTile(
            key: const Key('debug-consequences'),
            title: const Text('consequences JSON (phase 1, pre-validation)'),
            tilePadding: EdgeInsets.zero,
            children: [Text(report.rawLlmJson!, style: mono)],
          ),
        ],
        if (report.narrativeText != null &&
            report.narrativeText!.isNotEmpty) ...[
          ExpansionTile(
            key: const Key('debug-narrative'),
            title: const Text('narrative (phase 2)'),
            tilePadding: EdgeInsets.zero,
            children: [
              if (report.narrativePrompt != null)
                Text('prompt: ${report.narrativePrompt}', style: mono),
              Text(report.narrativeText!, style: mono),
            ],
          ),
        ],
      ],
    );
  }
}
