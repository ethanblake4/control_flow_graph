// ignore_for_file: non_constant_identifier_names

import 'dart:collection';
import 'dart:math';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

typedef SpillFunc = Operation Function(SSA ssa);
typedef ReloadFunc = Operation Function(SSA ssa);
typedef CopyFunc = Operation Function(SSA dest, SSA src);

const int32Max = 0x7fffffff;

void spill(
    CFG graph,
    int root,
    Map<int, BasicBlock> blocks,
    Set<Loop> loops,
    Map<int, RegType> types,
    Map<RegisterGroup, int> K,
    Map<int, Map<RegisterGroup, int>> maxPressure,
    Map<int, Map<SSA, SplayTreeSet<int>>> nextUseDistances,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, Set<SSA>> liveInSets,
    SpillFunc spillFunc,
    ReloadFunc reloadFunc) {
  //print('pressure: $maxPressure');
  //print('next uses: $nextUseDistances');
  final postorder = graph.depthFirstPostOrder(root).toList();
  final reversePostorder = postorder.reversed.toList();

  final loopHeaders = loops.map((loop) => loop.header).toSet();

  final wend = <int, Set<SSA>>{};
  final send = <int, Set<SSA>>{};

  final groupLock = <SSA, RegisterGroup>{};

  final defer = <int, (Set<SSA> deferW, Set<SSA> deferS)>{};

  for (final block in reversePostorder) {
    final (wentry, takeSlots) = loopHeaders.contains(block)
        ? _initLoopHeader(graph, block, blocks, loops, K, maxPressure,
            nextUseDistances, uses, types, liveInSets)
        : _initBlockUsual(
            graph, blocks, K, groupLock, nextUseDistances, types, block, wend);

    final preds = graph.predecessorsOf(block).toList();

    final sentry = <SSA>{};
    for (final pred in preds) {
      sentry.addAll(send[pred] ?? {});
    }

    for (final pred in preds) {
      if (send[pred] == null) {
        defer[pred] = (wentry, sentry);
        continue;
      }
      final spill = sentry.difference(send[pred]!).intersection(wend[pred]!);
      for (final ssa in spill) {
        final code = blocks[pred]!.code;
        code.insert(code.length, spillFunc(ssa));
      }
    }

    /*for (final pred in preds) {
      if (wend[pred] == null) {
        continue;
      }
      final reload = wentry.difference(wend[pred]!);
      for (final ssa in reload) {
        final code = blocks[pred]!.code;
        //print('preds reload $ssa in block $pred');
        //code.insert(code.length, reloadFunc(ssa));
      }
    }*/

    final (we, se) = _minAlgorithm(blocks[block]!, wentry, sentry, types,
        nextUseDistances[block]!, K, takeSlots, uses, spillFunc, reloadFunc);

    //print('block $block wend $we send $se');

    wend[block] = we;
    send[block] = se;

    if (defer.containsKey(block)) {
      final (deferW, deferS) = defer[block]!;
      final spill = deferS.difference(se).intersection(we);
      for (final ssa in spill) {
        final code = blocks[block]!.code;
        code.insert(code.length, spillFunc(ssa));
      }

      final reload = deferW.difference(we);
      for (final ssa in reload) {
        final code = blocks[block]!.code;
        code.insert(code.length, reloadFunc(ssa));
        //print('reload $ssa in block $block');
      }
      defer.remove(block);
    }
  }
}

/*
Algorithm 1 The Min algorithm

def minAlgorithm(block, W, S):
for insn ∈ block.insnuctions:
R ← insn.uses \ W
for use ∈ R:
W ← W ∪ {use}
S ← S ∪ {use}
limit(W, S, insn, k)
limit(W, S, insn.next,k−|insn.defs|)
W ← W ∪ {insn.defs}
add reloads for vars in R
in front of insn
*/

(Set<SSA> Wend, Set<SSA> Send) _minAlgorithm(
    BasicBlock block,
    Set<SSA> W,
    Set<SSA> S,
    Map<int, RegType> types,
    Map<SSA, SplayTreeSet<int>> nextUseDistances,
    Map<RegisterGroup, int> K,
    Map<RegisterGroup, int> takeSlots,
    Map<SSA, Set<SpecifiedOperation>> uses,
    SpillFunc spillFunc,
    ReloadFunc reloadFunc) {
  //print(block.id);
  //print(W);
  //print(nextUseDistances);
  final groupLock = <SSA, RegisterGroup>{};
  var comp = 0;
  for (var i = 0; i < block.code.length; i++) {
    final insn = block.code[i];
    final R = insn is PhiNode
        ? <SSA>{}
        : (insn.readsFrom.difference(W)
          ..removeWhere((e) => e.name.startsWith('@')));
    for (final use in R) {
      W.add(use);
      S.add(use);
    }

    int spills;

    //print('limit $insn W: $W S: $S');
    if (insn is PhiNode) {
      W.removeAll(insn.sources);
    }

    (W, spills) = _limit(block, i, comp, W, S, insn, types, groupLock, K,
        nextUseDistances, spillFunc);
    i += spills;
    comp += spills;

    final wtc = insn is ParallelCopy
        ? insn.copies.map((c) => c.$2)
        : (insn.writesTo == null ? <SSA>[] : [insn.writesTo!]);
    final wtf = wtc.where((c) => !c.name.startsWith('@'));
    final isControlFlow = insn.writesTo == ControlFlowGraph.branch;
    final isLast = i == block.code.length - 1;

    if (!isControlFlow) {
      final next = isLast ? block.code[i] : block.code[i + 1];
      final Map<RegisterGroup, int> nextK;
      if (wtf.isNotEmpty) {
        nextK = {...K};
        for (final wt in wtf) {
          if (groupLock.containsKey(wt)) {
            nextK[groupLock[wt]!] = nextK[groupLock[wt]!]! - 1;
          } else {
            // find next open takeSlot
            var found = false;
            final groups = types[wt.type]!.regGroups;
            for (final gr in groups) {
              takeSlots.putIfAbsent(gr, () => 0);
              if (takeSlots[gr]! < K[gr]!) {
                takeSlots[gr] = takeSlots[gr]! + 1;
                nextK[gr] = nextK[gr]! - 1;
                groupLock[wt] = gr;
                found = true;
                break;
              }
            }
            if (!found) {
              takeSlots[groups.first] = takeSlots[groups.first]! + 1;
              nextK[groups.first] = nextK[groups.first]! - 1;
              groupLock[wt] = groups.first;
            }
          }
        }
      } else {
        nextK = K;
      }

      //print('limi2 $insn W: $W S: $S');

      (W, spills) = _limit(block, i, comp, W, S, next, types, groupLock, nextK,
          nextUseDistances, spillFunc);
      i += spills;
      comp += spills;
    }

    W.addAll(wtf);
    for (final use in R) {
      // add reloads for vars in R in front of insn
      //print('areload $use in block ${block.id}');
      block.code.insert(i, reloadFunc(use));
      i++;
      comp++;
    }

    //print('postl $insn W: $W S: $S');
  }
  return (W, S);
}

/*
def limit(W, S, insn, m):
sort(W, insn)
for v ∈ W[m:−1]:
if v ∈/ S ∧ nextUse(insn,v) != ∞:
add a spill for v before insn
S ← S \ {v}
W ← W[0:m]
*/
(Set<SSA>, int) _limit(
  BasicBlock block,
  int i,
  int comp,
  Set<SSA> W,
  Set<SSA> S,
  Operation insn,
  Map<int, RegType> types,
  Map<SSA, RegisterGroup> groupLock,
  Map<RegisterGroup, int> K,
  Map<SSA, SplayTreeSet<int>> nextUseDistances,
  SpillFunc spillFunc,
) {
  final nextUseAtInsn = <SSA, int>{};
  var ci = i - comp;
  // for each next use choose smallest value greater than i, or int32Max
  for (final v in W) {
    final nextUse = nextUseDistances[v]
            ?.firstWhere((e) => e >= ci, orElse: () => int32Max) ??
        int32Max;
    nextUseAtInsn[v] = nextUse == int32Max ? int32Max : nextUse - ci;
  }
  //print('nu $insn ${intMapString(nextUseAtInsn)}');
  final Wsorted = W.toList()
    ..sort((a, b) => nextUseAtInsn[a]! - nextUseAtInsn[b]!);

  final Wgrouped = <RegisterGroup, List<SSA>>{};

  for (final v in Wsorted) {
    if (groupLock.containsKey(v)) {
      final group = groupLock[v]!;
      Wgrouped.putIfAbsent(group, () => []);
      Wgrouped[group]!.add(v);
    } else {
      final rt = types[v.type]!;
      for (final group in rt.regGroups) {
        Wgrouped.putIfAbsent(group, () => []);
        Wgrouped[group]!.add(v);
      }
    }
  }

  final spill = <SSA>{};

  for (final m in K.entries) {
    final group = m.key;
    final limit = m.value;

    final Wg = Wgrouped[group] ?? [];
    final limto = max(0, min(limit, Wg.length));
    for (final ssa in Wg.sublist(0, limto)) {
      if (spill.contains(ssa)) {
        spill.remove(ssa);
        S.remove(ssa);
      }
    }

    final v = Wg.sublist(limto);

    for (final ssa in v) {
      if (!S.contains(ssa) &&
          !spill.contains(ssa) &&
          nextUseAtInsn.containsKey(ssa) &&
          nextUseAtInsn[ssa]! < int32Max) {
        spill.add(ssa);
      }
      S.remove(ssa);
    }

    Wgrouped[group] = Wg.sublist(0, limto);
  }

  for (final s in spill) {
    block.code.insert(i, spillFunc(s));
    i++;
  }

  W = Wgrouped.values.fold(<SSA>{}, (a, b) => a..addAll(b));
  return (W, spill.length);
}

/*
def initUsual(block):
  freq ← map()
  take ← ∅
  cand ← ∅
  for pred in block.preds:
    for var in pred.Wend:
      freq[var] ← freq[var] + 1
      cand ← cand ∪ {var}
    if freq[var] = |block.preds|:
      cand ← cand \ {var}
      take ← take ∪ {var}
  entry ← block.firstInstruction
  sort(cand, entry)
  return take ∪ cand[0:k−|take|]
*/
(Set<SSA> result, Map<RegisterGroup, int> takeSlots) _initBlockUsual(
    CFG graph,
    Map<int, BasicBlock> blocks,
    Map<RegisterGroup, int> K,
    Map<SSA, RegisterGroup> groupLock,
    Map<int, Map<SSA, SplayTreeSet<int>>> nextUseDistances,
    Map<int, RegType> types,
    int block,
    Map<int, Set<SSA>> wend) {
  final freq = <SSA, int>{};
  final take = <SSA>{};
  final takeSlots = <RegisterGroup, int>{};
  final cand = <SSA>{};

  final preds = graph.predecessorsOf(block);
  for (final pred in preds) {
    for (final v in wend[pred] ?? <SSA>{}) {
      if (v.name.startsWith('@')) {
        continue;
      }
      freq[v] = (freq[v] ?? 0) + 1;
      cand.add(v);

      if (freq[v] == preds.length) {
        take.add(v);
        final t = types[v.type]!;
        var found = false;
        for (final gr in t.regGroups) {
          if (!takeSlots.containsKey(gr)) {
            takeSlots[gr] = 0;
          }
          if (takeSlots[gr]! < K[gr]!) {
            takeSlots[gr] = takeSlots[gr]! + 1;
            found = true;
            break;
          }
        }
        if (!found) {
          takeSlots[t.regGroups.first] = takeSlots[t.regGroups.first]! + 1;
        }
        cand.remove(v);
      }
    }
  }

  // sort cand by next use distance
  final sorted = cand.toList()
    ..sort((a, b) =>
        (nextUseDistances[block]![a]?.firstOrNull ?? int32Max) -
        (nextUseDistances[block]![b]?.firstOrNull ?? int32Max));

  SSA? next(RegisterGroup gr) {
    final i = sorted.indexWhere((s) => types[s.type]!.regGroups.contains(gr));
    if (i == -1) return null;
    takeSlots[gr] = takeSlots[gr]! + 1;
    return sorted.removeAt(i);
  }

  final result = {...take};

  for (final gr in takeSlots.keys) {
    while (K[gr]! - takeSlots[gr]! > 0) {
      final v = next(gr);
      if (v == null) {
        break;
      }
      result.add(v);
    }
  }

  return (result, takeSlots);
}

/*
def initLoopHeader(block):
  entry ← block.firstInstruction
  loop ← loopOf(block)
  alive ← block.phis ∪ block.liveIn
  cand ← usedInLoop(loop, alive)
  liveThrough ← alive \ cand
  if |cand| < k:
    freeLoop ← k − loop.maxPressure
      + |liveThrough|
    sort(liveThrough, entry)
    add ← liveThrough[0:freeLoop]
  else:
    sort(cand, entry)
    cand ← cand[0:k]
    add ← ∅
  return cand ∪ add
*/
(Set<SSA> result, Map<RegisterGroup, int> takeSlots) _initLoopHeader(
    CFG graph,
    int block,
    Map<int, BasicBlock> blocks,
    Set<Loop> loops,
    Map<RegisterGroup, int> K,
    Map<int, Map<RegisterGroup, int>> maxPressure,
    Map<int, Map<SSA, SplayTreeSet<int>>> nextUseDistances,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, RegType> types,
    Map<int, Set<SSA>> liveIn) {
  final usesCopy = {...uses};
  usesCopy.removeWhere((ssa, _) => ssa.name.startsWith('@'));
  final loop = loops.firstWhere((loop) => loop.header == block);
  final phis = blocks[block]!.code.whereType<PhiNode>().map((e) => e.target);
  final alive = phis.toSet().union(liveIn[block]!);

  final loopBlocks = loop.blocks.toSet();
  final cand = alive
      .where((v) => usesCopy[v]!.any((op) => loopBlocks.contains(op.blockId)))
      .toSet();

  final liveThrough = alive.difference(cand);

  final groupedCand = <RegisterGroup, Set<SSA>>{};
  final takeSlots = <RegisterGroup, int>{};
  for (final v in cand) {
    final rt = types[v.type]!;
    for (final group in rt.regGroups) {
      groupedCand.putIfAbsent(group, () => {});
      groupedCand[group]!.add(v);
    }
  }

  final groupedLiveThrough = <RegisterGroup, Set<SSA>>{};
  for (final v in liveThrough) {
    final rt = types[v.type]!;
    for (final group in rt.regGroups) {
      groupedLiveThrough.putIfAbsent(group, () => {});
      groupedLiveThrough[group]!.add(v);
    }
  }

  final add = <SSA>{};
  for (final k in K.entries) {
    final group = k.key;
    groupedCand.putIfAbsent(group, () => {});
    groupedLiveThrough.putIfAbsent(group, () => {});
    groupedCand[group] = groupedCand[group]!.difference(add);
    groupedLiveThrough[group] = groupedLiveThrough[group]!.difference(add);
    final freeLoop = K[group]! -
        (maxPressure[block]?[group] ?? 0) +
        groupedLiveThrough[group]!.length;
    if (groupedCand[group]!.length < K[group]!) {
      final sorted = [...groupedLiveThrough[group]!]..sort((a, b) =>
          (nextUseDistances[block]![a]?.firstOrNull ?? int32Max) -
          (nextUseDistances[block]![b]?.firstOrNull ?? int32Max));
      final sub = sorted.sublist(0, min(sorted.length, freeLoop));
      takeSlots[group] = sub.length;
      add.addAll(sub);
    } else {
      final sorted = [...groupedCand[group]!]..sort((a, b) =>
          (nextUseDistances[block]![a]?.firstOrNull ?? int32Max) -
          (nextUseDistances[block]![b]?.firstOrNull ?? int32Max));
      groupedCand[group] =
          sorted.sublist(0, min(sorted.length, K[group]!)).toSet();
      takeSlots[group] = groupedCand[group]!.length;
    }
  }

  return (
    groupedCand.values.fold(<SSA>{}, (a, b) => a..addAll(b)).union(add),
    takeSlots
  );
}

String intMapString(Map<dynamic, int> set) {
  var res = '{', i = 0;
  for (final item in set.entries) {
    res += '${item.key}: ';
    if (item.value >= int32Max - 1000) {
      res += '∞';
      /*if (item.value < int32Max) {
        res += '-${int32Max - item.value}';
      }*/
    } else {
      res += '${item.value}';
    }
    if (i < set.length - 1) res += ', ';
    i++;
  }
  return '$res}';
}
