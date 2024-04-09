import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

bool isLiveInUsingMergeSet(
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
  for (final use in u) {
    var t = use.blockId;
    while (!(blockDefines[t] ?? const {}).contains(variable)) {
      if (t == block || mr.contains(t)) {
        return true;
      }
      t = dominators[t]!;
    }
  }
  return false;
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
