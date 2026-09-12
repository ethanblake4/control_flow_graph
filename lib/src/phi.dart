import 'package:control_flow_graph/control_flow_graph.dart';

void insertPhiNodesInto(Map<int, BasicBlock> ids, Map<String, Set<int>> globals,
    Map<int, Set<int>> mergeSets) {
  final phiNodes = <int, Set<(String, int)>>{};

  for (var sourceBlock in mergeSets.keys) {
    final assignments = <(String, int)>{};
    final sb = ids[sourceBlock]!;
    for (var op in sb.code) {
      final writesTo = op.writesTo;
      if (writesTo != null && globals.containsKey(writesTo.name)) {
        assignments.add((writesTo.name, writesTo.type));
      }
    }
    for (var targetBlock in mergeSets[sourceBlock]!) {
      for (var assignment in assignments) {
        phiNodes
            .putIfAbsent(targetBlock, () => <(String, int)>{})
            .add(assignment);
      }
    }
  }

  for (var block in phiNodes.keys) {
    final sb = ids[block]!;
    for (var (name, type) in phiNodes[block]!) {
      sb.code
          .insert(0, PhiNode(SSA(name, type: type), {SSA(name, type: type)}));
    }
  }
}

// Lower phis to parallel edge copies. Critical edges get dedicated blocks so
// copies cannot overwrite values needed by a different successor.
void removePhiNodesFrom(
    ControlFlowGraph cfg, Operation Function(SSA left, SSA right) assign,
    {void Function(int predecessor, int oldTarget, int newTarget)?
        onSplitEdge}) {
  final graph = cfg.graph;
  for (final predecessor in graph.vertices.toList()) {
    final successors = graph.successorsOf(predecessor).toList();
    if (successors.length < 2) continue;
    for (final target in successors) {
      if (graph.predecessorsOf(target).length < 2) continue;
      final edge = BasicBlock<Operation>([], label: '#phi_${cfg.lastBlockId}');
      cfg.append(edge, true);
      final edgeId = edge.id!;
      final current = graph.successorsOf(predecessor).toList();
      for (final next in current) {
        graph.removeEdge(predecessor, next);
      }
      for (final next in current) {
        graph.addEdge(predecessor, next == target ? edgeId : next);
      }
      graph.addEdge(edgeId, target);
      for (final phi in cfg[target]!.code.whereType<PhiNode>()) {
        final value = phi.incoming.remove(predecessor);
        if (value != null) phi.incoming[edgeId] = value;
      }
      onSplitEdge?.call(predecessor, target, edgeId);
    }
  }
  var temporary = 0;
  for (final blockId in graph.vertices.toList()) {
    final block = cfg[blockId]!;
    final phis = block.code.whereType<PhiNode>().toList();
    if (phis.isEmpty) continue;
    for (final predecessor in graph.predecessorsOf(blockId).toList()) {
      final pending = <SSA, SSA>{};
      for (final phi in phis) {
        final source = phi.incoming[predecessor];
        if (source == null) {
          throw StateError(
              'Missing phi input for edge $predecessor -> $blockId');
        }
        if (source != phi.target) pending[phi.target] = source;
      }
      final copies = <Operation>[];
      while (pending.isNotEmpty) {
        final ready = pending.keys
            .where((target) => !pending.values.contains(target))
            .firstOrNull;
        if (ready != null) {
          copies.add(assign(ready, pending.remove(ready)!));
        } else {
          final target = pending.keys.first;
          final saved = SSA('#phi_copy_${temporary++}', type: target.type);
          copies.add(assign(saved, target));
          for (final entry in pending.entries.toList()) {
            if (entry.value == target) pending[entry.key] = saved;
          }
        }
      }
      final code = cfg[predecessor]!.code;
      final insertion = code.isNotEmpty &&
              (code.last.isTerminator ||
                  code.last.writesTo == ControlFlowGraph.branch)
          ? code.length - 1
          : code.length;
      code.insertAll(insertion, copies);
    }
    block.code.removeWhere((op) => op is PhiNode);
  }
}
