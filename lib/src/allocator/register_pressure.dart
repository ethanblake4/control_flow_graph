import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/liveness.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/graph.dart';

final _liveinCache = <int, Map<SSA, bool>>{};

bool _cachedLiveIn(
    int root,
    int block,
    SSA variable,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets) {
  final cache = _liveinCache[block] ??= {};
  return cache.putIfAbsent(variable, () {
    return isLiveInUsingMergeSet(
        root, block, variable, blockDefines, uses, dominators, mergeSets);
  });
}

Map<int, Map<RegisterGroup, int>> computeRegisterPressure(
    CFG graph,
    int root,
    Map<int, BasicBlock> ids,
    Map<int, RegType> types,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets) {
  final pressure = <int, Map<RegisterGroup, int>>{};
  final maxPressure = <int, Map<RegisterGroup, int>>{};
  final outVars = <int, Set<SSA>>{};
  final worklist = ListQueue<(int, int)>()..add((-1, root));
  final visitedEdges = <Edge<int, void>>{};

  while (worklist.isNotEmpty) {
    final (from, id) = worklist.removeFirst();
    if (visitedEdges.contains(Edge<int, void>.directed(from, id))) {
      continue;
    }
    visitedEdges.add(Edge<int, void>.directed(from, id));
    final block = ids[id]!;
    pressure[id] ??= {};
    maxPressure[id] ??= {};

    final successors = graph.successorsOf(id);

    if (outVars[id] == null) {
      outVars[id] = _pressureFromBlock(
          root,
          id,
          block,
          successors,
          pressure[id]!,
          maxPressure[id]!,
          types,
          uses,
          blockDefines,
          dominators,
          mergeSets);
    }

    for (final succ in graph.successorsOf(id)) {
      final succPressure = pressure[succ] ??= {};
      final succBlock = ids[succ]!;
      final captured = _variablesCapturedByPhi(succBlock);
      final liveOut = outVars[id]!.difference(captured);

      for (final lv in liveOut) {
        if (_cachedLiveIn(
            root, succ, lv, blockDefines, uses, dominators, mergeSets)) {
          final groups = types[lv.type < 0 ? 0 : lv.type]!.regGroups;
          var spill = 0;
          for (final group in groups) {
            final p = succPressure[group] ?? 0;
            if (p < group.registers.length) {
              succPressure[group] = p + 1;
            } else {
              spill++;
            }
          }
          succPressure[groups.first] = succPressure[groups.first]! + spill;
        }
      }

      worklist.add((id, succ));
    }
  }

  return maxPressure;
}

Set<SSA> _variablesCapturedByPhi(BasicBlock block) {
  final captured = <SSA>{};
  for (final op in block.code) {
    if (op is! PhiNode) {
      return captured;
    }
    for (final input in op.readsFrom) {
      captured.add(input);
    }
  }
  return captured;
}

Set<SSA> _pressureFromBlock(
    int root,
    int id,
    BasicBlock block,
    Iterable<int> successors,
    Map<RegisterGroup, int> pressure,
    Map<RegisterGroup, int> maxPressure,
    Map<int, RegType> types,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, Set<SSA>> blockDefines,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets) {
  final outVars = <SSA>{};
  final usesInBlock = <SSA, int>{};
  final usedInBlock = <SSA, int>{};
  for (final op in block.code) {
    final writesTo = <SSA>{};
    if (op is ParallelCopy) {
      for (final (target, _) in op.copies) {
        writesTo.add(target);
      }
    } else if (op.writesTo != null) {
      writesTo.add(op.writesTo!);
    }
    final filt = writesTo.where((w) => !w.name.startsWith('@'));
    if (filt.isNotEmpty) {
      for (final wt in filt) {
        outVars.add(wt);
        final groups = types[wt.type < 0 ? 0 : wt.type]!.regGroups;
        var spill = 0;
        for (final group in groups) {
          final p = pressure[group] ?? 0;
          if (p < group.registers.length) {
            pressure[group] = p + 1;
            if (p + 1 > (maxPressure[group] ?? 0)) {
              maxPressure[group] = p + 1;
            }
          } else {
            spill++;
          }
        }
        pressure[groups.first] = pressure[groups.first]! + spill;
        if (pressure[groups.first]! > (maxPressure[groups.first] ?? 0)) {
          maxPressure[groups.first] = pressure[groups.first]!;
        }
      }
    } else {
      for (final input in op.readsFrom) {
        final groups = types[input.type < 0 ? 0 : input.type]!.regGroups;
        for (final group in groups) {
          final p = pressure[group] ?? 0;
          if (p > (maxPressure[group] ?? 0)) {
            maxPressure[group] = p;
          }
        }
        if (usesInBlock[input] == null) {
          usesInBlock[input] =
              uses[input]!.where((o) => o.blockId == id).length;
        }
        usedInBlock[input] = (usedInBlock[input] ?? 0) + 1;
        if (usedInBlock[input] != usesInBlock[input]) {
          continue;
        }

        for (final succ in successors) {
          if (_cachedLiveIn(
              root, succ, input, blockDefines, uses, dominators, mergeSets)) {
            continue;
          }
        }

        for (final group in groups) {
          final p = pressure[group] ?? 0;
          if (p > 0) {
            pressure[group] = p - 1;
          }
        }
      }
    }
  }

  return outVars;
}
