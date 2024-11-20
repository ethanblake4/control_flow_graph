import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

class NextUseDistanceComputationData {
  Map<int, Map<SSA, int>> nextUseDistances = {};
  Map<int, Map<RegisterGroup, int>> registerPressure = {};

  NextUseDistanceComputationData(this.nextUseDistances, this.registerPressure);
}

Map<int, Map<SSA, SplayTreeSet<int>>> computeGlobalNextUseDistances(
    ControlFlowGraph cfg,
    CFG graph,
    int root,
    Map<int, BasicBlock> ids,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, RegType> regTypes,
    Set<Loop> loops,
    Map<int, int> dominators) {
  Map<int, Map<SSA, SplayTreeSet<int>>> nextUseIns = {};
  Map<int, Map<SSA, int>> nextUseOuts = {};
  //print('lo:');
  //print(cfg.isLiveIn(SSA('x', version: 0), cfg[2]!));

  final loopExitEdges = loops.expand((loop) => loop.exits);

  for (final id in ids.keys) {
    nextUseIns[id] = {};
    nextUseOuts[id] = {};
  }

  var hasChange = true;

  final Set<(int, int)> visitedEdges = {};

  while (hasChange) {
    hasChange = false;
    for (final blockId in graph.depthFirst(root)) {
      final block = ids[blockId]!;
      final nextUseIn = nextUseIns[blockId]!;
      final nextUseOut = nextUseOuts[blockId]!;
      for (final succ in graph.successorsOf(blockId)) {
        final edge = (blockId, succ);
        for (final useIn in nextUseIns[succ]!.entries) {
          if (!nextUseOut.containsKey(useIn.key) ||
              useIn.value.first < nextUseOut[useIn.key]!) {
            nextUseOut[useIn.key] =
                useIn.value.first + (loopExitEdges.contains(edge) ? 100000 : 0);
          }
        }

        if (visitedEdges.contains(edge)) {
          continue;
        }

        visitedEdges.add(edge);
      }

      Set<SSA> definedOrSeen = {};
      for (var i = 0; i < block.code.length; i++) {
        final op = block.code[i];
        for (final u in op.readsFrom) {
          if (!nextUseIn.containsKey(u)) {
            nextUseIn[u] = SplayTreeSet();
          }
          if (i < (nextUseIn[u]!.firstOrNull ?? 0x7fffffff)) {
            hasChange = true;
          }
          nextUseIn[u]!.add(i);
          definedOrSeen.add(u);
        }

        /*
        final writesTo = op.writesTo;
        if (writesTo != null) {
          definedOrSeen.add(writesTo);
        }*/
      }

      for (final entry in nextUseOut.entries) {
        final op = entry.key;
        if (definedOrSeen.contains(op)) {
          continue;
        }

        final v = entry.value + block.code.length;
        if (!nextUseIn.containsKey(op) || !nextUseIn[op]!.contains(v)) {
          hasChange = true;
          nextUseIn.putIfAbsent(op, () => SplayTreeSet()).add(v);
        }
      }
    }
  }

  return nextUseIns;
}
