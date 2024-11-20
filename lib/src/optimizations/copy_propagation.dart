import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';

void ssaBasedCopyPropagation(ControlFlowGraph cfg, int root) {
  final copyRelations = <SSA, Set<SSA>>{};
  final ssaGraph = cfg.ssaGraph;
  final mergeSets = cfg.mergeSets;
  final cfgWorklist = ListQueue<int>.of([root]);
  final executableEdges = <int, Set<int>>{};
  final ssaGraphCandidates = <int, List<(int, Set<int>)>>{};

  while (cfgWorklist.isNotEmpty) {
    final blockId = cfgWorklist.removeFirst();
    final block = cfg[blockId]!;
    final code = block.code;
    final codelen = code.length;
    for (var i = 0; i < codelen; i++) {
      final op = code[i];
      final spec = SpecifiedOperation(blockId, op);
      if (op is PhiNode) {
        final preds = ssaGraph.predecessorsOf(spec);
        for (final pred in preds) {
          final predBlockId = pred.blockId;
          final ee = executableEdges[predBlockId];
          if (ee != null && ee.contains(blockId)) {
            final o = pred.op;
            final wt =
                o is ParallelCopy ? o.copies.map((c) => c.$2) : [o.writesTo!];
            copyRelations.putIfAbsent(op.target, () => {}).addAll(wt);
          }
        }
      } else if (op.writesTo != ControlFlowGraph.branch) {
        if (op.type == AssignmentOp.assign) {
          final wt =
              op is ParallelCopy ? op.copies.map((c) => c.$2) : [op.writesTo!];
          for (final w in wt) {
            copyRelations.putIfAbsent(w, () => {}).add(op.readsFrom.first);
          }
        }
      }
      for (final succ in ssaGraph.successorsOf(spec)) {
        ssaGraphCandidates
            .putIfAbsent(succ.blockId, () => [])
            .add((blockId, {blockId}));
      }
    }
    final execFromThis = executableEdges.putIfAbsent(blockId, () => {});
    final successors = cfg.graph.successorsOf(blockId);

    var excluded = false;

    if (codelen > 0) {
      final lastOp = code.last;
      if (lastOp.writesTo == ControlFlowGraph.branch) {
        final compEq = lastOp.type == ComparisonOp.equal; // otherwise not-equal
        final readsFromIt = lastOp.readsFrom.iterator..moveNext();
        final left = readsFromIt.current;
        readsFromIt.moveNext();
        final right = readsFromIt.current;
        final cr = copyRelations[left];
        if (cr != null && cr.length == 1 && cr.first == right) {
          if (successors.length == 2) {
            final succIt = successors.iterator..moveNext();
            if (compEq) {
              final cur = succIt.current;
              if (execFromThis.add(cur)) {
                cfgWorklist.add(cur);
              }
            } else {
              succIt.moveNext();
              final cur = succIt.current;
              if (execFromThis.add(cur)) {
                cfgWorklist.add(cur);
              }
            }
            excluded = true;
          }
        }
      } else {
        final markRemove = <int>[];
        for (final succ in successors.skip(1)) {
          markRemove.add(succ);
        }
        for (final mr in markRemove) {
          cfg.graph.removeEdge(blockId, mr);
        }
      }
    }
    if (!excluded) {
      for (final succ in successors) {
        if (execFromThis.add(succ)) {
          cfgWorklist.add(succ);
        }
      }
    }

    for (final target in execFromThis) {
      final ssaCandidates = ssaGraphCandidates.remove(target);
      if (ssaCandidates == null) {
        continue;
      }
      for (final (bid, _) in ssaCandidates) {
        executableEdges.putIfAbsent(bid, () => {}).add(target);
      }
    }

    for (final mergeBlock in mergeSets[blockId] ?? {}) {
      final ssaCandidates = ssaGraphCandidates[mergeBlock] ?? [];
      var j = 0;
      final remove = <int>[];
      for (final cd in ssaCandidates) {
        final (_, bset) = cd;
        if (!bset.contains(blockId)) {
          continue;
        }
        for (final target in execFromThis) {
          if ((mergeSets[target] ?? {}).contains(mergeBlock)) {
            bset.add(target);
          }
        }
        bset.remove(blockId);
        if (bset.isEmpty) {
          remove.add(j);
        }
        j++;
      }
      var k = 0;
      for (final j in remove) {
        ssaCandidates.removeAt(j - k);
        k++;
      }
    }
  }

  final uses = cfg.uses!;
  for (final ssa in copyRelations.keys) {
    final copies = copyRelations[ssa]!;
    if (copies.isEmpty || copies.length > 1) {
      continue;
    }
    final ssaUses = uses.remove(ssa);
    if (ssaUses == null) {
      continue;
    }
    final copy = copies.first;
    for (final use in ssaUses) {
      final ssaSet = use.op.readsFrom;
      ssaSet.remove(ssa);
      ssaSet.add(copies.first);
      final def = cfg.defines![copy]!;
      ssaGraph.addEdge(def, use);
      for (final s in ssaGraph.predecessorsOf(use).toList()) {
        if (!ssaSet.contains(s.op.writesTo)) {
          ssaGraph.removeEdge(s, use);
        }
      }
    }
  }
}
