/// Per-delta accept/clamp/reject records (§3.4, §9). Every proposal from the
/// LLM gets exactly one decision; the debug report carries all of them.
library;

enum DeltaOutcome { accepted, clamped, rejected }

class DeltaDecision {
  const DeltaDecision({
    required this.section,
    required this.proposal,
    required this.outcome,
    this.from,
    this.to,
    this.reason = '',
  });

  /// Which proposal section: clock | inventory | stats | status |
  /// relationships | quest.
  final String section;

  /// The original proposal as JSON, verbatim.
  final Map<String, Object?> proposal;
  final DeltaOutcome outcome;

  /// For clamps: the proposed value and what it was clamped to.
  final Object? from;
  final Object? to;
  final String reason;

  bool get applied => outcome != DeltaOutcome.rejected;

  Map<String, Object?> toJson() => {
        'section': section,
        'proposal': proposal,
        'outcome': outcome.name,
        'from': from,
        'to': to,
        'reason': reason,
      };

  factory DeltaDecision.fromJson(Map<String, Object?> json) => DeltaDecision(
        section: json['section'] as String,
        proposal: (json['proposal'] as Map<String, Object?>?) ?? const {},
        outcome: DeltaOutcome.values.byName(json['outcome'] as String),
        from: json['from'],
        to: json['to'],
        reason: json['reason'] as String? ?? '',
      );
}
