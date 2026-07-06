/// Relationship graph viewer (§12): characters on a ring, directed edges
/// colored by mean dimension value, tap-friendly legend below.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:living_worlds_engine/living_worlds_engine.dart';

import '../world_store.dart';

class RelationshipsTab extends StatelessWidget {
  const RelationshipsTab({super.key, required this.store});

  final WorldStore store;

  @override
  Widget build(BuildContext context) {
    final p = store.projection!;
    final characters = p.characters.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final edges = p.edges.values.toList();

    if (characters.length < 2) {
      return const Center(
          child: Text('Add a second character to grow the graph.'));
    }

    return Column(
      children: [
        Expanded(
          child: CustomPaint(
            key: const Key('relationship-graph'),
            size: Size.infinite,
            painter: _GraphPainter(
              characters: characters,
              edges: edges,
              theme: Theme.of(context),
            ),
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              if (edges.isEmpty)
                const Text('No relationship edges yet — they grow from play.'),
              for (final e in edges)
                ListTile(
                  dense: true,
                  title: Text(
                      '${p.characters[e.fromChar]?.name ?? e.fromChar} → '
                      '${p.characters[e.toChar]?.name ?? e.toChar}'),
                  subtitle: Text(e.dims.entries
                      .map((d) =>
                          '${d.key}: ${d.value.toStringAsFixed(0)}')
                      .join(' · ')),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(
      {required this.characters, required this.edges, required this.theme});

  final List<Character> characters;
  final List<RelationshipEdge> edges;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 60;
    final positions = <String, Offset>{};
    for (var i = 0; i < characters.length; i++) {
      final angle = 2 * math.pi * i / characters.length - math.pi / 2;
      positions[characters[i].id] = center +
          Offset(radius * math.cos(angle), radius * math.sin(angle));
    }

    for (final e in edges) {
      final from = positions[e.fromChar];
      final to = positions[e.toChar];
      if (from == null || to == null || e.dims.isEmpty) continue;
      final mean =
          e.dims.values.fold(0.0, (a, b) => a + b) / e.dims.length;
      final t = ((mean + 10) / 20).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = Color.lerp(Colors.redAccent, Colors.greenAccent, t)!
        ..strokeWidth = 2 + (mean.abs() / 10) * 3
        ..style = PaintingStyle.stroke;

      // Offset both endpoints perpendicular so A->B and B->A don't overlap.
      final dir = (to - from);
      final norm = dir.distance == 0
          ? Offset.zero
          : Offset(-dir.dy, dir.dx) / dir.distance * 6;
      canvas.drawLine(from + norm, to + norm, paint);
      // Arrowhead at 85% along.
      final tip = from + norm + dir * 0.85;
      final back = dir.distance == 0 ? Offset.zero : dir / dir.distance * 10;
      final side = dir.distance == 0
          ? Offset.zero
          : Offset(-dir.dy, dir.dx) / dir.distance * 5;
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(tip.dx - back.dx + side.dx, tip.dy - back.dy + side.dy)
          ..lineTo(tip.dx - back.dx - side.dx, tip.dy - back.dy - side.dy)
          ..close(),
        paint..style = PaintingStyle.fill,
      );
    }

    for (final c in characters) {
      final pos = positions[c.id]!;
      canvas.drawCircle(
          pos,
          22,
          Paint()
            ..color = c.alive
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.errorContainer);
      final tp = TextPainter(
        text: TextSpan(
          text: c.name + (c.alive ? '' : ' †'),
          style: theme.textTheme.labelMedium,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos + Offset(-tp.width / 2, 26));
      final initial = TextPainter(
        text: TextSpan(
            text: c.name.isEmpty ? '?' : c.name[0],
            style: theme.textTheme.titleMedium),
        textDirection: TextDirection.ltr,
      )..layout();
      initial.paint(
          canvas, pos + Offset(-initial.width / 2, -initial.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.characters != characters || old.edges != edges;
}
