import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

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

// removal of phi nodes after SSA transformation, optimizations etc
void removePhiNodesFrom(
    CFG graph,
    Graph<SpecifiedOperation, void> ssaGraph,
    Map<int, BasicBlock> ids,
    int root,
    Operation Function(SSA left, SSA right) assign) {
  for (var blockId in graph.depthFirst(root)) {
    final phiNodes = <PhiNode>{};
    final assignments = <int, Set<Operation>>{};
    final replacements = <int, Map<Operation, SSA>>{};
    final block = ids[blockId]!;
    for (final op in block.code) {
      if (op is PhiNode) {
        phiNodes.add(op);
        for (final predecessor in graph.predecessorsOf(blockId)) {
          assignments[predecessor] ??= {};
          replacements[predecessor] ??= {};
          final preds =
              ssaGraph.predecessorsOf(SpecifiedOperation(blockId, op));
          final pred =
              preds.firstWhere((element) => element.blockId == predecessor);
          final src = pred.op.writesTo!;
          if (src != op.target) {
            final ps = ssaGraph.successorsOf(pred);
            if (ps.length == 1 && pred.op is! PhiNode) {
              replacements[predecessor]![pred.op] = op.target;
            } else {
              assignments[predecessor]!.add(assign(op.target, src));
            }
          }
        }
      } else {
        break;
      }
    }

    for (final assignment in assignments.entries) {
      final predecessor = ids[assignment.key]!;
      final code = predecessor.code;
      final length = code.length;
      for (final op in assignment.value) {
        if (length > 0 &&
            code[length - 1].writesTo == ControlFlowGraph.branch) {
          code.insert(length - 1, op);
        } else {
          code.add(op);
        }
      }
    }

    for (final replacement in replacements.entries) {
      final predecessor = ids[replacement.key]!;
      final code = predecessor.code;
      for (final entry in replacement.value.entries) {
        final index = code.indexWhere((element) => element == entry.key);
        code[index] = code[index].copyWith(writesTo: entry.value);
      }
    }

    for (var i = 0; i < phiNodes.length; i++) {
      block.code.removeAt(0);
    }
  }
}
