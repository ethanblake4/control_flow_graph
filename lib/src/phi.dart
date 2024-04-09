import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/ssa.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

void insertPhiNodesInto(Map<int, BasicBlock> ids, Map<String, Set<int>> globals,
    Map<int, Set<int>> mergeSets) {
  final phiNodes = <int, Set<String>>{};

  for (var sourceBlock in mergeSets.keys) {
    final assignments = <String>{};
    final sb = ids[sourceBlock]!;
    for (var op in sb.code) {
      final writesTo = op.writesTo;
      if (writesTo != null && globals.containsKey(writesTo.name)) {
        assignments.add(writesTo.name);
      }
    }
    for (var targetBlock in mergeSets[sourceBlock]!) {
      for (var assignment in assignments) {
        phiNodes.putIfAbsent(targetBlock, () => <String>{}).add(assignment);
      }
    }
  }

  for (var block in phiNodes.keys) {
    final sb = ids[block]!;
    for (var assignment in phiNodes[block]!) {
      sb.code.insert(0, PhiNode(SSA(assignment), {SSA(assignment)}));
    }
  }
}

// removal of phi nodes after SSA transformation, optimizations etc
void removePhiNodesFrom(
    CFG graph,
    Graph<int, int> djGraph,
    Map<int, BasicBlock> ids,
    int root,
    Operation Function(SSA left, SSA right) assign) {
  for (var blockId in graph.depthFirst(root)) {
    final phiNodes = <PhiNode>{};
    final assignments = <int, Set<Operation>>{};
    final block = ids[blockId]!;
    for (final op in block.code) {
      if (op is PhiNode) {
        phiNodes.add(op);
        for (final predecessor in graph.predecessorsOf(blockId)) {
          assignments[predecessor] ??= {};
          assignments[predecessor]!.add(assign(
              op.target,
              findVariableInSSAGraph(
                  ids, djGraph, predecessor, op.target.name)));
        }
      } else {
        break;
      }
    }

    for (var i = 0; i < phiNodes.length; i++) {
      block.code.removeAt(0);
    }

    for (final assignment in assignments.entries) {
      final predecessor = ids[assignment.key]!;
      final length = predecessor.code.length;
      for (final op in assignment.value) {
        if (predecessor.code[length - 1].writesTo == ControlFlowGraph.branch) {
          predecessor.code.insert(length - 1, op);
        } else {
          predecessor.code.add(op);
        }
      }
    }
  }
}
