import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/ssa.dart';
import 'package:more/more.dart';

void insertPhiNodesInto(ControlFlowGraph cfg) {
  final globals = cfg.globals;
  final mergeSets = cfg.mergeSets;
  final phiNodes = <int, Set<String>>{};

  for (var sourceBlock in mergeSets.keys) {
    final assignments = <String>{};
    final sb = cfg[sourceBlock]!;
    for (var op in sb.code) {
      for (var write in op.writesTo) {
        if (globals.containsKey(write.name)) {
          assignments.add(write.name);
        }
      }
    }
    for (var targetBlock in mergeSets[sourceBlock]!) {
      for (var assignment in assignments) {
        phiNodes.putIfAbsent(targetBlock, () => <String>{}).add(assignment);
      }
    }
  }

  for (var block in phiNodes.keys) {
    final sb = cfg[block]!;
    for (var assignment in phiNodes[block]!) {
      sb.code.insert(0, PhiNode(SSA(assignment), {SSA(assignment)}));
    }
  }
}

// removal of phi nodes after SSA transformation, optimizations etc
void removePhiNodesFrom(
    ControlFlowGraph cfg, Operation Function(SSA left, SSA right) assign) {
  for (var blockId in cfg.graph.depthFirst(cfg.root.id!)) {
    final phiNodes = <PhiNode>{};
    final assignments = <int, Set<Operation>>{};
    final block = cfg[blockId]!;
    for (final op in block.code) {
      if (op is PhiNode) {
        phiNodes.add(op);
        for (final predecessor in cfg.graph.predecessorsOf(blockId)) {
          assignments[predecessor] ??= {};
          assignments[predecessor]!.add(assign(op.target,
              findVariableInSSAGraph(cfg, predecessor, op.target.name)));
        }
      } else {
        break;
      }
    }

    for (var i = 0; i < phiNodes.length; i++) {
      block.code.removeAt(0);
    }

    for (final assignment in assignments.entries) {
      final predecessor = cfg[assignment.key]!;
      final length = predecessor.code.length;
      for (final op in assignment.value) {
        if (predecessor.code[length - 1].writesTo
            .contains(ControlFlowGraph.branch)) {
          predecessor.code.insert(length - 1, op);
        } else {
          predecessor.code.add(op);
        }
      }
    }
  }
}
