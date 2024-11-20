import 'dart:collection';
import 'dart:math';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/allocator/spill.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/ssa.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

void regalloc(
    CFG graph,
    int root,
    Map<int, BasicBlock> blocks,
    Set<Loop> loops,
    Map<int, RegType> types,
    Map<Type, InstructionCreator> creators,
    Map<RegisterGroup, int> K,
    Map<int, Map<RegisterGroup, int>> maxPressure,
    Map<int, Map<SSA, SplayTreeSet<int>>> nextUseDistances,
    Map<SSA, Set<SpecifiedOperation>> uses,
    Map<int, Set<SSA>> liveInSets,
    Map<int, Set<SSA>> liveOutSets,
    SpillFunc spillFunc,
    ReloadFunc reloadFunc,
    CopyFunc copyFunc) {
  final postorder = graph.depthFirstPostOrder(root).toList();
  final reversePostorder = postorder.reversed.toList();
  final blockOrder = <int, int>{};
  final spillLive = <int, Set<SSA>>{};
  for (var i = 0; i < reversePostorder.length; i++) {
    blockOrder[reversePostorder[i]] = i;
  }
  final startRegs = <int, Map<SSA, int>>{};
  final endRegs = <int, Map<SSA, int>>{};

  for (final block in reversePostorder) {
    _regallocBlock(
        root,
        block,
        graph,
        creators,
        blocks,
        blocks[block]!,
        liveOutSets[block]!,
        types,
        startRegs,
        endRegs,
        blockOrder,
        spillLive,
        copyFunc,
        nextUseDistances);
  }
}

void _regallocBlock(
    int root,
    int id,
    CFG graph,
    Map<Type, InstructionCreator> creators,
    Map<int, BasicBlock> blocks,
    BasicBlock block,
    Set<SSA> liveOut,
    Map<int, RegType> types,
    Map<int, Map<SSA, int>> startRegs,
    Map<int, Map<SSA, int>> endRegs,
    Map<int, int> blockOrder,
    Map<int, Set<SSA>> spillLive,
    CopyFunc copyFunc,
    Map<int, Map<SSA, SplayTreeSet<int>>> nextUseDistances) {
  print('Regalloc block $id');
  Set<int> compatibleRegisters(SSA ssa) {
    final type = types[ssa.type];
    if (type == null) {
      return <int>{};
    }
    return type.regGroups.fold(<int>{}, (r, g) => r..addAll(g.registers));
  }

  final live = {...liveOut};
  final used = <int>{};
  for (final operation in block.code.reversed) {
    if (live.contains(operation.writesTo)) {
      live.remove(operation.writesTo);
    }
    if (operation is PhiNode) {
      continue;
    }
    if (operation.type is CallOp) {
      live.clear();
    }
    for (final read in operation.readsFrom) {
      live.add(read);
    }
  }

  final preds = graph.predecessorsOf(id).toList();
  final registers = BiMap<SSA, int>();
  final spillPhis = <PhiNode>[];
  final phis = <PhiNode>[];

  final phiRegs = <int, int>{};

  var phiLen = 0;
  for (var i = 0; i < block.code.length; i++) {
    final operation = block.code[i];
    if (operation is PhiNode) {
      phis.add(operation);
    } else {
      phiLen = i;
      break;
    }
  }

  if (id == root) {
    //skip
  } else if (preds.length == 1) {
    for (final register in endRegs[preds.single]!.entries) {
      final pRegs = endRegs[preds.single];
      if (live.contains(register.key)) {
        registers[register.key] = pRegs![register.key]!;
      }
    }
  } else {
    print('multiple preds');
    var idx = -1, bi = -1;
    for (var i = 0; i < preds.length; i++) {
      final p = preds[i];
      if (blockOrder[p]! > blockOrder[id]!) {
        continue;
      }
      if (idx == -1) {
        idx = i;
        bi = p;
        continue;
      }
      final sel = preds[idx];
      final slp = spillLive[p]?.length ?? 0;
      final sls = spillLive[sel]?.length ?? 0;
      if (slp < sls) {
        idx = i;
        bi = p;
      } else if (slp == sls) {
        if (blockOrder[sel]! < blockOrder[p]!) {
          idx = i;
          bi = p;
        }
      }
    }

    print('IDx $idx');

    final pRegs = endRegs[bi];
    for (final register in pRegs!.entries) {
      //if (live.contains(register.key)) {
      registers[register.key] = register.value;
      //}
    }

    // first pass
    for (var i = 0; i < phis.length; i++) {
      final phi = phis[i];
      final value = phi.writesTo!;
      if (registers.containsKey(value)) {
        block.code[i] = phi.copyWith(
            writesTo: AllocatedSSA.fromSSA(value, registers[value]!));
        continue;
      }
      final potential = compatibleRegisters(phi.writesTo!);
      for (final reg in potential) {
        if (!phiRegs.containsValue(reg)) {
          registers[value] = reg;
          phiRegs[i] = reg;
          block.code[i] =
              phi.copyWith(writesTo: AllocatedSSA.fromSSA(value, reg));
          break;
        }
      }
      if (!phiRegs.containsKey(i)) {
        phiRegs[i] = -1;
      }
    }

    print('pass 2');

    // Second pass - deallocate all in-register phi inputs.
    for (var i = 0; i < phis.length; i++) {
      final phi = phis[i];
      if (!phiRegs.containsKey(i) || phiRegs[i] == -1) {
        continue;
      }
      final a = phi.readsFrom.toList()[idx];
      final regs = compatibleRegisters(a)
          .difference(phiRegs.values.toSet())
          .difference(used);
      if (regs.isEmpty || phi.isRematerializable) {
        continue;
      }
      final dst = AllocatedSSA.fromSSA(a.copy()..version = -1, regs.first);
      final copy = copyFunc(dst, AllocatedSSA.fromSSA(a, registers[a]!));
      block.code.insert(phiLen++, copy);
      registers[dst] = regs.first;
      registers.remove(phi.writesTo);
    }

    print('pass 3');

    // Third pass - pick registers for phis whose input
    // was not in a register in the primary predecessor.
    for (var i = 0; i < phis.length; i++) {
      final phi = phis[i];
      final args = phi.readsFrom.toList();
      if (phiRegs.containsKey(i) && phiRegs[i] != -1) {
        continue;
      }
      final value = phi.writesTo!;

      var regs = compatibleRegisters(value)
          .difference(phiRegs.values.toSet())
          .difference(used);

      for (var i = 0; i < preds.length; i++) {
        final p = preds[i];
        if (i == idx) {
          continue;
        }
        int ri = -1;
        final arg = args[i];
        for (final er in endRegs[p]!.entries) {
          if (er.key == arg) {
            ri = er.value;
            break;
          }
        }
        if (ri != -1 && regs.contains(ri)) {
          regs = {ri};
          break;
        }
      }
      if (regs.isNotEmpty) {
        phiRegs[i] = regs.first;
      }
    }

    print('pick');

    // pick registers for phis
    for (var i = 0; i < phis.length; i++) {
      final phi = phis[i];
      final reg = phiRegs[i];
      if (reg == null || reg == -1) {
        spillPhis.add(phi);
        continue;
      }
      registers[phi.writesTo!] = reg;
      block.code[i] =
          phi.copyWith(writesTo: AllocatedSSA.fromSSA(phi.writesTo!, reg));
    }

    print('remove live');

    for (final r in {...registers}.entries) {
      if (phiRegs.containsValue(r.value)) {
        continue;
      }
      if (!live.contains(r.key)) {
        registers.remove(r.key);
      }
    }
  }

  print('remove next use');

  final nextUse = nextUseDistances[id] ?? <SSA, SplayTreeSet<int>>{};
  for (var i = 0; i < phis.length; i++) {
    final phi = phis[i];
    final nu = (nextUse[phi.writesTo!]) ?? SplayTreeSet<int>();
    if (nu.isEmpty || nu.first < i) {
      registers.remove(phi.writesTo!);
      continue;
    }
  }

  final desired = <SSA, LinkedHashMap<int, Set<int>>>{};

  print('desire successors');

  final successors = graph.successorsOf(id).toList();
  for (final successor in successors) {
    for (final reg in (startRegs[successor] ?? <SSA, int>{}).entries) {
      final last = desired[reg.key]?.keys.last ?? maxSafeInteger - 1;
      final loc = min(last + 1, block.code.length);
      final des = desired[reg.key] ?? <int, Set<int>>{};
      des.putIfAbsent(loc, () => <int>{}).add(reg.value);
    }
    final scode = blocks[successor]!.code;
    for (var i = 0; i < scode.length; i++) {
      final op = scode[i];
      if (op is! PhiNode) {
        break;
      }
      if (op.writesTo is! AllocatedSSA) {
        for (final read in op.readsFrom) {
          if (read is AllocatedSSA) {
            desired
                .putIfAbsent(read, () => LinkedHashMap())
                .putIfAbsent(block.code.length, () => <int>{})
                .add(read.register);
          }
        }
      }
    }
  }

  print('creators');

  for (var i = block.code.length - 1; i >= phiLen; i--) {
    final op = block.code[i];
    final writesTo = op.writesTo;
    if (writesTo == null) {
      continue;
    }
    final creator = creators[op.runtimeType];
    final readsFrom = op.readsFrom.toList();
    for (var j = 0; j < readsFrom.length; j++) {
      final wanted = creator?.variants
              ?.map((v) => v.arguments[j])
              .fold(<int>{}, (a, b) => a..add(b)) ??
          <int>{};
      final rf = readsFrom[j];
      final regspec = compatibleRegisters(rf);
      desired
          .putIfAbsent(rf, () => LinkedHashMap())
          .putIfAbsent(i, () => <int>{})
        ..clear()
        ..addAll(wanted.intersection(regspec));
    }
  }

  // TODO process in-register function calls

  print('forward');
  print(desired);

  for (var i = phiLen; i < block.code.length; i++) {
    final op = block.code[i];
    var writesTo = op.writesTo;
    //final regspec = compatibleRegisters(op.writesTo!);
    //if (regspec.length == 1) {
    //
    //}
    final readsFrom = op.readsFrom.toList();
    print(op.runtimeType);
    Iterable<Variant>? variants = creators[op.runtimeType]!.variants;
    for (var j = 0; j < readsFrom.length; j++) {
      final read = readsFrom[j];
      final pref = desired[read];
      if (pref == null) {
        continue;
      }
      int? high, low, selected;
      Set<int> regs;
      print('selecting $op: $read');
      if (registers.containsKey(read)) {
        continue;
      }
      select:
      while (true) {
        (high, low, regs) = _nearest(pref, i, high: high, low: low);
        for (final reg in regs) {
          if (!registers.containsValue(reg)) {
            selected = reg;
            break select;
          }
        }
        if ((high ?? 0) >= pref.keys.max() || (low ?? 0) < 0) {
          break;
        }
        high = high == null ? null : high + 1;
        low = low == null ? null : low - 1;
      }
      if (selected == null) {
        break;
      }
      readsFrom[j] = AllocatedSSA.fromSSA(readsFrom[j], selected);
      variants = variants?.where((v) => v.arguments[j] == selected);
    }
    for (final variant in variants ?? <Variant>[]) {
      if (writesTo != null && variant.result != null) {
        if (!registers.containsValue(variant.result)) {
          writesTo = AllocatedSSA.fromSSA(writesTo, variant.result!);
          registers[writesTo] = variant.result!;
          break;
        }
      }
    }

    block.code[i] =
        op.copyWith(readsFrom: readsFrom.toSet(), writesTo: writesTo);
  }

  endRegs[id] = registers;
}

(int? hi, int? low, Set<int> res) _nearest(Map<int, Set<int>> prefs, int i,
    {int? high, int? low}) {
  if (prefs.containsKey(i)) {
    return (null, null, prefs[i]!);
  }
  var ih = high ?? i + 1;
  var il = low ?? i - 1;
  final max = prefs.keys.max();
  while (il >= 0 || ih <= max) {
    final h = prefs[high];
    if (h != null) {
      return (ih, il, h);
    }
    final l = prefs[low];
    if (l != null) {
      return (ih, il, l);
    }
    ih += 1;
    il -= 1;
  }
  return (ih, il, <int>{});
}
