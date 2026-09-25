import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';

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
  // Removing a leaf can make its inputs unused, so continue until stable.
  bool changed;
  do {
    changed = false;
    for (final define in cfg.defines!.entries.toList()) {
      final value = define.key;
      final spec = define.value;
      if (!(canRemove?.call(spec.op) ?? spec.op.isPure) ||
          value == ControlFlowGraph.branch ||
          (cfg.uses![value]?.isNotEmpty ?? false)) {
        continue;
      }
      cfg[spec.blockId]!.code.remove(spec.op);
      for (final input in spec.op.readsFrom) {
        cfg.uses![input]?.remove(spec);
      }
      cfg.ssaGraph.removeVertex(spec);
      cfg.defines!.remove(value);
      cfg.blockDefines![spec.blockId]?.remove(value);
      cfg.uses!.remove(value);
      changed = true;
    }
  } while (changed);
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

      for (final op in block.code) {
        final readsFrom = op.readsFrom;
        for (final ssa in readsFrom) {
          final spec = SpecifiedOperation(blockId, op);
          final defSpec = cfg.defines![ssa];
          if (defSpec != null) {
            cfg.ssaGraph.removeEdge(defSpec, spec);
          }
          cfg.uses![ssa]?.remove(spec);
        }
      }

      final bdefines = cfg.blockDefines![blockId];
      if (bdefines != null) {
        for (final define in bdefines) {
          final d = cfg.defines!.remove(define)!;
          cfg.ssaGraph.removeVertex(d);
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
