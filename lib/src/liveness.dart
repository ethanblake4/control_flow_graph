import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

bool isLiveInUsingMergeSet(
    int root,
    int block,
    SSA variable,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets) {
  final mr = mergeSets[block] ?? {};
  final u = uses[variable];
  if (u == null || u.isEmpty) {
    return false;
  }
  final phiUses = <int>{};
  for (final use in u) {
    var t = use.blockId;
    while (!(blockDefines[t] ?? const {}).contains(variable)) {
      if (t == block || mr.contains(t)) {
        if (use.op is! PhiNode) {
          return true;
        }
        phiUses.add(t);
      }
      if (t == block || t == root) {
        break;
      }
      t = dominators[t]!;
    }
  }
  if (phiUses.isEmpty) {
    return false;
  }
  var t = dominators[block];
  if (t == block) {
    return true;
  }
  while (true) {
    for (final def in blockDefines[t] ?? const <SSA>{}) {
      if (def.name == variable.name && def.version > variable.version) {
        return false;
      }
    }
    final idom = dominators[t]!;
    if (idom == block || idom == root || (phiUses..remove(t)).isEmpty) {
      return true;
    }
    t = idom;
  }
}

Map<int, Set<SSA>> allLiveInUsingMergeSet(
    int root,
    CFG graph,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets) {
  final liveInSets = <int, Set<SSA>>{};
  final worklist = ListQueue<(int, int, Set<SSA>)>()..add((-1, root, {}));
  final visitedEdges = <Edge<int, void>>{};

  while (worklist.isNotEmpty) {
    final (from, id, vin) = worklist.removeFirst();
    if (visitedEdges.contains(Edge<int, void>.directed(from, id))) {
      continue;
    }
    visitedEdges.add(Edge<int, void>.directed(from, id));
    final liveIn = {
      ...vin.where((v) => isLiveInUsingMergeSet(
          root, id, v, blockDefines, uses, dominators, mergeSets))
    };
    liveInSets[id] = liveIn;
    final next = liveIn.union(blockDefines[id] ?? const {});
    for (final succ in graph.successorsOf(id)) {
      worklist.add((id, succ, next));
    }
  }

  return liveInSets;
}

/// Compute liveout sets using the livein sets of successor blocks.
Map<int, Set<SSA>> allLiveOutUsingMergeSet(
    int root,
    CFG graph,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets) {
  final liveOutSets = <int, Set<SSA>>{};
  final postorder = graph.depthFirstPostOrder(root).toList();
  final livein = allLiveInUsingMergeSet(
      root, graph, blockDefines, uses, dominators, mergeSets);
  for (final id in postorder) {
    final successors = graph.successorsOf(id);
    final ins = successors.map((s) => livein[s] ?? const {});
    if (ins.isEmpty) {
      liveOutSets[id] = {};
      continue;
    }

    liveOutSets[id] = ins.reduce((a, b) => a.union(b));
  }
  return liveOutSets;
}

bool isLiveOutUsingMergeSet(
    int block,
    SSA variable,
    CFG graph,
    Map<int, Set<SSA>> blockDefines,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, int> dominators,
    Map<int, Set<int>> mergeSets,
    Map<int, Set<int>> liveoutMsCache) {
  final bd = blockDefines[block];
  final u = uses[variable];

  if (u == null || u.isEmpty) {
    return false;
  }

  if (bd != null && bd.contains(variable)) {
    // Case when variable is defined in block, if any of the uses are outside
    // the block then it must be live-out.
    for (final use in u) {
      if (use.blockId != block) {
        return true;
      }
    }
  }

  final Set<int> ms;
  if (liveoutMsCache.containsKey(block)) {
    ms = liveoutMsCache[block]!;
  } else {
    ms = {};
    final successors = graph.depthFirst(block).skip(1);
    for (final successor in successors) {
      final set = mergeSets[successor];
      if (set != null) {
        ms.addAll(set);
      }
    }
    liveoutMsCache[block] = ms;
  }

  for (final use in u) {
    var t = use.blockId;
    while (!(blockDefines[t] ?? const {}).contains(variable)) {
      if (ms.contains(t)) {
        return true;
      }
      t = dominators[t]!;
    }
  }

  return false;
}
