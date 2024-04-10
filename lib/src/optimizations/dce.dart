import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';

void removeUnusedSSADefines(ControlFlowGraph cfg) {
  final markRemove = <SSA>{};
  for (final define in cfg.defines!.entries) {
    final spec = define.value;
    if (cfg.ssaGraph.successorsOf(spec).isEmpty) {
      cfg[spec.blockId]!.code.remove(spec.op);
      cfg.ssaGraph.removeVertex(spec);
      markRemove.add(define.key);
    }
  }

  for (final remove in markRemove) {
    final spec = cfg.defines!.remove(remove);
    cfg.blockDefines![spec!.blockId]?.remove(remove);
  }
}

void trimBlocks(ControlFlowGraph cfg) {
  final markRemove = <int>{};
  final graph = cfg.graph;

  for (final blockId in graph.vertices) {
    final block = cfg[blockId]!;
    final neighbors = graph.neighboursOf(blockId);
    if (block.code.isEmpty ||
        neighbors.isEmpty ||
        markRemove.containsAll(neighbors)) {
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
