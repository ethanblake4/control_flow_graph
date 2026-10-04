import 'package:control_flow_graph/control_flow_graph.dart';

/// Removes unused SSA definitions until no further result becomes dead.
///
/// [canRemove] is an optional policy for the calling compiler. When supplied,
/// it replaces [Operation.isPure], so callers must certify that every selected
/// operation can be discarded without observable effects. The graph's SSA
/// metadata is rebuilt first because lowering passes may have rewritten code.
void removeUnusedSSADefines(
  ControlFlowGraph cfg, {
  bool Function(Operation)? canRemove,
}) {
  cfg.refreshSSA();
  final defines = cfg.defines!;
  final uses = cfg.uses!;
  final pending = [
    for (final value in defines.keys)
      if (value != ControlFlowGraph.branch &&
          !(uses[value]?.isNotEmpty ?? false))
        value,
  ];
  final removed = <int, Set<Operation>>{};
  while (pending.isNotEmpty) {
    final value = pending.removeLast();
    final spec = defines[value];
    if (spec == null || !(canRemove?.call(spec.op) ?? spec.op.isPure)) {
      continue;
    }
    removed.putIfAbsent(spec.blockId, Set.identity).add(spec.op);
    defines.remove(value);
    cfg.blockDefines![spec.blockId]?.remove(value);
    uses.remove(value);
    for (final input in spec.op.readsFrom) {
      final consumers = uses[input];
      // Only the transition to no consumers can expose another dead result.
      // Cycles without a dead leaf remain intact, as in the fixed-point pass.
      if (consumers != null &&
          consumers.remove(spec) &&
          consumers.isEmpty &&
          input != ControlFlowGraph.branch &&
          defines.containsKey(input)) {
        pending.add(input);
      }
    }
  }
  if (removed.isNotEmpty) {
    cfg.invalidateSSAEdges();
    for (final entry in removed.entries) {
      // Compact once per affected block, preserving surviving operation order.
      cfg[entry.key]!.code.removeWhere(entry.value.contains);
    }
  }
}

void trimBlocks(ControlFlowGraph cfg) {
  final markRemove = <int>{};
  final graph = cfg.graph;

  for (final blockId in graph.vertices) {
    final block = cfg[blockId]!;
    if (block == cfg.root) {
      continue;
    }
    final successors = graph.successorsOf(blockId).toList();
    // A terminal block may return or throw. Only bypass an empty block with
    // one successor; dropping a sink or merging multiple edges changes flow.
    final hasBranchingPredecessor = graph
        .predecessorsOf(blockId)
        .any((predecessor) => graph.successorsOf(predecessor).length > 1);
    // Edge insertion order encodes conditional destinations. Reconnecting a
    // branching predecessor here would reorder those destinations.
    if (block.code.isEmpty &&
        successors.length == 1 &&
        successors.single != blockId &&
        !hasBranchingPredecessor) {
      markRemove.add(blockId);

      final bdefines = cfg.blockDefines![blockId];
      if (bdefines != null) {
        for (final define in bdefines) {
          cfg.defines!.remove(define);
          cfg.invalidateSSAEdges();
        }
      }
    }
  }

  for (final remove in markRemove) {
    final incoming = graph.predecessorsOf(remove);
    final outgoing = graph.successorsOf(remove);

    for (final inBlock in incoming) {
      for (final outBlock in outgoing) {
        graph.addEdge(inBlock, outBlock);
      }
    }

    graph.removeVertex(remove);
  }
}
