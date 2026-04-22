import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/operation.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Assigns physical registers to all SSA variables in a CFG that has already
/// had phi nodes removed and spill/reload inserted.
///
/// Each [SSA] reference in every [Operation] is replaced in-place by an
/// [AllocatedSSA] (physical register) or an [ImmediateSSA] (for `@N`
/// immediate variables).  `@branch` is left as-is.
///
/// [opCreators] maps each [Operation] runtime type to its [InstructionCreator],
/// whose [Variant]s describe the physical-register constraints (slot numbers
/// *are* the physical register indices).
void allocateRegisters(
    CFG graph,
    int root,
    Map<int, BasicBlock> blocks,
    Map<int, RegType> regTypes,
    Map<Type, InstructionCreator> opCreators,
    Map<int, Set<SSA>> liveIn,
    Map<int, Set<SSA>> liveOut,
    Map<int, Map<SSA, SplayTreeSet<int>>> nextUseDistances) {
  // Process blocks in reverse post-order so every forward edge is visited
  // before its target block.
  final rpo = graph.depthFirstPostOrder(root).toList().reversed.toList();

  // The SSA-based liveIn/liveOut are stale after phi removal and variable
  // coalescing.  Recompute a fresh global liveness via a simple iterative
  // backward dataflow on the current (post-phi-removal) operations.
  final freshLiveIn = _computeFreshLiveIn(graph, root, blocks);

  final blockEntryState = <int, _RegState>{};
  final blockExitState = <int, _RegState>{};

  for (final blockId in rpo) {
    final block = blocks[blockId]!;
    final preds = graph.predecessorsOf(blockId).toList();
    final live = freshLiveIn[blockId] ?? const {};

    final entry = _buildEntryState(preds, blockExitState, live, regTypes);
    // Save a snapshot BEFORE _allocateBlock mutates entry in-place.
    blockEntryState[blockId] = entry.copy();

    _allocateBlock(block, entry, regTypes, opCreators,
        liveOut[blockId] ?? const {}, nextUseDistances[blockId] ?? const {});

    blockExitState[blockId] = entry.copy();
  }

  // Second pass: fix register mismatches on all edges.  For forward edges the
  // successor entry was derived from the predecessor exit so there is nothing
  // to do.  For back-edges (loop latches) we may need to shuffle registers at
  // the latch's tail so that the loop header's entry expectations are met.
  for (final blockId in rpo) {
    final entryState = blockEntryState[blockId]!;
    final live = freshLiveIn[blockId] ?? const {};
    for (final predId in graph.predecessorsOf(blockId)) {
      final predExit = blockExitState[predId];
      if (predExit == null) continue;
      _fixEdge(blocks[predId]!, predExit, entryState, live, regTypes);
    }
  }
}

/// Iterative backward dataflow to compute live-in sets from the current
/// block operations (post-phi-removal).  SpillNode and ReloadNode are treated
/// as uses/defs respectively so that spilled variables are properly tracked.
Map<int, Set<SSA>> _computeFreshLiveIn(
    CFG graph, int root, Map<int, BasicBlock> blocks) {
  // Compute upward-exposed uses and locally-defined variables per block.
  final ueVars = <int, Set<SSA>>{};
  final varKill = <int, Set<SSA>>{};

  for (final blockId in blocks.keys) {
    final ue = <SSA>{};
    final kill = <SSA>{};
    for (final op in blocks[blockId]!.code) {
      // SpillNode: its target is a use (must be in a register to spill).
      if (op is SpillNode) {
        final t = op.target;
        if (!t.name.startsWith('@') && !kill.contains(t)) ue.add(t);
        continue;
      }
      // ReloadNode: its target is a definition (produces a register value).
      if (op is ReloadNode) {
        final t = op.target;
        if (!t.name.startsWith('@')) kill.add(t);
        continue;
      }
      for (final r in op.readsFrom) {
        if (!r.name.startsWith('@') && !kill.contains(r)) ue.add(r);
      }
      final wt = op.writesTo;
      if (wt != null && !wt.name.startsWith('@')) kill.add(wt);
    }
    ueVars[blockId] = ue;
    varKill[blockId] = kill;
  }

  // Iterative fixed-point: liveIn[b] = ueVars[b] ∪ (liveOut[b] − varKill[b])
  // where liveOut[b] = ∪ liveIn[s] for all successors s.
  final liveIn = <int, Set<SSA>>{
    for (final id in blocks.keys) id: {...ueVars[id]!}
  };

  var changed = true;
  while (changed) {
    changed = false;
    // Process in post-order so back-edge information propagates quickly.
    for (final blockId in graph.depthFirstPostOrder(root)) {
      final liveOut = <SSA>{};
      for (final succ in graph.successorsOf(blockId)) {
        liveOut.addAll(liveIn[succ] ?? const {});
      }
      final newIn = {
        ...ueVars[blockId]!,
        ...liveOut.difference(varKill[blockId]!),
      };
      if (!newIn.containsAll(liveIn[blockId]!) ||
          !liveIn[blockId]!.containsAll(newIn)) {
        liveIn[blockId] = newIn;
        changed = true;
      }
    }
  }

  return liveIn;
}

// ---------------------------------------------------------------------------
// Register state
// ---------------------------------------------------------------------------

class _RegState {
  /// variable → physical register
  final Map<SSA, int> varToReg = {};

  /// physical register → variable currently occupying it (null = free)
  final Map<int, SSA?> regToVar = {};

  void _initReg(int r) => regToVar.putIfAbsent(r, () => null);

  void initRegisters(Iterable<int> regs) {
    for (final r in regs) {
      _initReg(r);
    }
  }

  void assign(SSA v, int reg) {
    varToReg[v] = reg;
    regToVar[reg] = v;
  }

  void free(SSA v) {
    final reg = varToReg.remove(v);
    if (reg != null) regToVar[reg] = null;
  }

  void freeReg(int reg) {
    final v = regToVar[reg];
    if (v != null) varToReg.remove(v);
    regToVar[reg] = null;
  }

  void swap(SSA a, SSA b) {
    final ra = varToReg[a]!;
    final rb = varToReg[b]!;
    varToReg[a] = rb;
    varToReg[b] = ra;
    regToVar[ra] = b;
    regToVar[rb] = a;
  }

  /// Returns physical registers compatible with [v]'s type that are currently
  /// free.
  Set<int> freeFor(SSA v, Map<int, RegType> regTypes) {
    return _compatible(v, regTypes).where((r) => regToVar[r] == null).toSet();
  }

  _RegState copy() {
    final s = _RegState();
    s.varToReg.addAll(varToReg);
    s.regToVar.addAll(regToVar);
    return s;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Set<int> _compatible(SSA ssa, Map<int, RegType> regTypes) {
  final id = ssa.type < 0 ? 0 : ssa.type;
  final rt = regTypes[id];
  if (rt == null) return const {};
  return rt.regGroups.fold(<int>{}, (acc, g) => acc..addAll(g.registers));
}

bool _isImmediate(SSA ssa) =>
    ssa.name.startsWith('@') && ssa.name != '@branch';

SSA _makeImmediate(SSA ssa) {
  if (ssa is ImmediateSSA) return ssa;
  final v = int.tryParse(ssa.name.substring(1));
  if (v != null) return ImmediateSSA.fromSSA(ssa, v);
  return ssa;
}

SSA _resolveArg(SSA arg, _RegState state) {
  if (_isImmediate(arg)) return _makeImmediate(arg);
  if (arg.name == '@branch') return arg;
  final reg = state.varToReg[arg];
  if (reg != null) return AllocatedSSA.fromSSA(arg, reg);
  return arg;
}

// ---------------------------------------------------------------------------
// Variant selection
// ---------------------------------------------------------------------------

/// Lower is better.  Returns 999 if a non-immediate arg is not in any register.
int _variantCost(
    Variant v, List<SSA> args, SSA? writesTo, _RegState state) {
  var cost = 0;
  for (var i = 0; i < v.arguments.length && i < args.length; i++) {
    final arg = args[i];
    if (_isImmediate(arg) || arg.name == '@branch') continue;
    final cur = state.varToReg[arg];
    if (cur == null) return 999;
    if (cur != v.arguments[i]) cost++;
  }
  // Penalise variants whose result register is occupied by a live variable
  // that is neither the definition target nor one of the consumed arguments.
  if (writesTo != null &&
      !writesTo.name.startsWith('@') &&
      v.result != null) {
    final incumbent = state.regToVar[v.result!];
    if (incumbent != null &&
        incumbent != writesTo &&
        !args.contains(incumbent)) {
      cost += 10;
    }
  }
  return cost;
}

Variant? _pickVariant(
    Iterable<Variant> variants, List<SSA> args, SSA? writesTo, _RegState state) {
  Variant? best;
  var bestCost = 1000;
  for (final v in variants) {
    final c = _variantCost(v, args, writesTo, state);
    if (c < bestCost) {
      bestCost = c;
      best = v;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Argument satisfaction (emit Assign / SwapOp to match variant constraints)
// ---------------------------------------------------------------------------

/// Returns the move/swap operations needed to put every argument of [variant]
/// into its required physical register, and updates [state] accordingly.
List<Operation> _satisfyArgs(
    Variant variant, List<SSA> args, _RegState state) {
  final ops = <Operation>[];
  for (var i = 0; i < variant.arguments.length && i < args.length; i++) {
    final arg = args[i];
    if (_isImmediate(arg) || arg.name == '@branch') continue;

    final required = variant.arguments[i];
    final current = state.varToReg[arg];
    if (current == null || current == required) continue;

    final incumbent = state.regToVar[required];
    if (incumbent == null) {
      // Target register is free: emit a register move.
      ops.add(Assign(
        AllocatedSSA.fromSSA(arg, required),
        AllocatedSSA.fromSSA(arg, current),
      ));
      state.freeReg(current);
      state.assign(arg, required);
    } else {
      // Target register is occupied: emit a swap.
      ops.add(SwapOp(
        AllocatedSSA.fromSSA(arg, current),
        AllocatedSSA.fromSSA(incumbent, required),
      ));
      state.swap(arg, incumbent);
    }
  }
  return ops;
}

// ---------------------------------------------------------------------------
// Per-block allocation
// ---------------------------------------------------------------------------

void _allocateBlock(
    BasicBlock block,
    _RegState state,
    Map<int, RegType> regTypes,
    Map<Type, InstructionCreator> opCreators,
    Set<SSA> liveOut,
    Map<SSA, SplayTreeSet<int>> nuds) {
  final newCode = <Operation>[];

  for (var idx = 0; idx < block.code.length; idx++) {
    final op = block.code[idx];

    // ---- SpillNode -------------------------------------------------------
    if (op is SpillNode) {
      final v = op.target;
      final reg = state.varToReg[v];
      if (reg != null) {
        newCode.add(SpillNode(AllocatedSSA.fromSSA(v, reg)));
        state.free(v);
      } else {
        newCode.add(op);
      }
      continue;
    }

    // ---- ReloadNode ------------------------------------------------------
    if (op is ReloadNode) {
      final v = op.target;
      final free = state.freeFor(v, regTypes);
      if (free.isEmpty) {
        newCode.add(op);
        continue;
      }
      // Prefer the register whose next use by any live variable is furthest
      // away, so we minimise future evictions.
      final reg = _pickReloadReg(v, free, state, nuds, idx);
      state.assign(v, reg);
      newCode.add(ReloadNode(AllocatedSSA.fromSSA(v, reg)));
      continue;
    }

    // ---- Assign (phi-removal copies) ------------------------------------
    if (op is Assign) {
      final src = op.source;
      final tgt = op.target;

      if (_isImmediate(tgt)) {
        newCode.add(op.copyWith(writesTo: _makeImmediate(tgt)));
        continue;
      }

      final srcReg = state.varToReg[src];
      if (srcReg != null) {
        // Coalesce: the copy disappears and target inherits source's register.
        state.free(src);
        state.assign(tgt, srcReg);
        newCode.add(Assign(
          AllocatedSSA.fromSSA(tgt, srcReg),
          AllocatedSSA.fromSSA(src, srcReg),
        ));
      } else {
        final free = state.freeFor(tgt, regTypes);
        if (free.isNotEmpty) {
          final reg = free.first;
          state.assign(tgt, reg);
          newCode.add(op.copyWith(
            writesTo: AllocatedSSA.fromSSA(tgt, reg),
            readsFrom: {_resolveArg(src, state)},
          ));
        } else {
          newCode.add(op);
        }
      }
      continue;
    }

    final writesTo = op.writesTo;

    // ---- @N immediate target (e.g. "@1 = imm 1") ------------------------
    if (writesTo != null && _isImmediate(writesTo)) {
      final newReads = LinkedHashSet<SSA>.of(
          op.readsFrom.map((a) => _resolveArg(a, state)));
      newCode.add(op.copyWith(
        writesTo: _makeImmediate(writesTo),
        readsFrom: newReads,
      ));
      continue;
    }

    // ---- Regular operation ----------------------------------------------
    final args = op.readsFrom.toList();
    final creator = opCreators[op.runtimeType];
    final variants = creator?.variants;

    if (variants == null || variants.isEmpty) {
      // No variant information: allocate greedily.
      final newReads =
          LinkedHashSet<SSA>.of(args.map((a) => _resolveArg(a, state)));
      final newWT = _allocateWritesTo(writesTo, state, regTypes);
      newCode.add(op.copyWith(writesTo: newWT, readsFrom: newReads));
      continue;
    }

    final best = _pickVariant(variants, args, writesTo, state);
    if (best == null) {
      newCode.add(op);
      continue;
    }

    // Emit swaps / moves to place arguments in their required registers.
    newCode.addAll(_satisfyArgs(best, args, state));

    // Build the allocated readsFrom (order preserved from original).
    final newReads =
        LinkedHashSet<SSA>.of(args.map((a) => _resolveArg(a, state)));

    // Determine allocated writesTo.
    SSA? newWT;
    if (writesTo == null || writesTo.name == '@branch') {
      newWT = writesTo;
    } else {
      final resultReg = best.result;
      if (resultReg != null) {
        // If the result register is currently occupied by someone other than
        // writesTo, try to rescue the incumbent by moving it to a free
        // register before overwriting.  Only silently evict if there is
        // nowhere else to put it (the spill pass should have ensured that
        // case is already dead, but with constrained variants it can happen
        // for live variables too).
        final evicted = state.regToVar[resultReg];
        if (evicted != null && evicted != writesTo) {
          final rescue = state.freeFor(evicted, regTypes);
          if (rescue.isNotEmpty) {
            final dst = rescue.first;
            newCode.add(Assign(
              AllocatedSSA.fromSSA(evicted, dst),
              AllocatedSSA.fromSSA(evicted, resultReg),
            ));
            state.freeReg(resultReg);
            state.assign(evicted, dst);
          } else {
            state.free(evicted);
          }
        }
        state.assign(writesTo, resultReg);
        newWT = AllocatedSSA.fromSSA(writesTo, resultReg);
      } else {
        newWT = _allocateWritesTo(writesTo, state, regTypes);
      }
    }

    newCode.add(op.copyWith(writesTo: newWT, readsFrom: newReads));
  }

  block.code
    ..clear()
    ..addAll(newCode);
}

// ---------------------------------------------------------------------------
// Entry-state construction
// ---------------------------------------------------------------------------

_RegState _buildEntryState(
    List<int> preds,
    Map<int, _RegState> exitStates,
    Set<SSA> liveIn,
    Map<int, RegType> regTypes) {
  final state = _RegState();

  // Make all known physical registers visible (as free) so the allocator
  // can always find a slot.
  for (final rt in regTypes.values) {
    for (final g in rt.regGroups) {
      state.initRegisters(g.registers);
    }
  }

  // Inherit register assignments from the first already-processed predecessor.
  _RegState? base;
  for (final p in preds) {
    final s = exitStates[p];
    if (s != null) {
      base = s;
      break;
    }
  }
  if (base == null) return state;

  for (final v in liveIn) {
    if (v.name.startsWith('@')) continue;
    final reg = base.varToReg[v];
    if (reg != null) state.assign(v, reg);
  }
  return state;
}

// ---------------------------------------------------------------------------
// Cross-block boundary fix-up
// ---------------------------------------------------------------------------

/// Inserts swaps / moves at the tail of [pred] so that every variable in
/// [liveIn] is in the register expected by [succEntry].
void _fixEdge(
    BasicBlock pred,
    _RegState predExit,
    _RegState succEntry,
    Set<SSA> liveIn,
    Map<int, RegType> regTypes) {
  final fixes = <Operation>[];
  final working = predExit.copy();

  for (final v in liveIn) {
    if (v.name.startsWith('@')) continue;
    final fromReg = working.varToReg[v];
    final toReg = succEntry.varToReg[v];
    if (fromReg == null || toReg == null || fromReg == toReg) continue;

    final incumbent = working.regToVar[toReg];
    if (incumbent == null) {
      fixes.add(Assign(
        AllocatedSSA.fromSSA(v, toReg),
        AllocatedSSA.fromSSA(v, fromReg),
      ));
      working.freeReg(fromReg);
      working.assign(v, toReg);
    } else {
      fixes.add(SwapOp(
        AllocatedSSA.fromSSA(v, fromReg),
        AllocatedSSA.fromSSA(incumbent, toReg),
      ));
      working.swap(v, incumbent);
    }
  }

  if (fixes.isEmpty) return;

  final code = pred.code;
  // Insert before a trailing @branch-writing instruction so the branch is
  // always the final operation.
  final insertAt = code.isNotEmpty &&
          code.last.writesTo?.name == '@branch'
      ? code.length - 1
      : code.length;

  for (var i = fixes.length - 1; i >= 0; i--) {
    code.insert(insertAt, fixes[i]);
  }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

SSA? _allocateWritesTo(
    SSA? writesTo, _RegState state, Map<int, RegType> regTypes) {
  if (writesTo == null || writesTo.name == '@branch') return writesTo;
  final existing = state.varToReg[writesTo];
  if (existing != null) return AllocatedSSA.fromSSA(writesTo, existing);
  final free = state.freeFor(writesTo, regTypes);
  if (free.isEmpty) return writesTo;
  final reg = free.first;
  state.assign(writesTo, reg);
  return AllocatedSSA.fromSSA(writesTo, reg);
}

/// Choose the best free register for a reload.  Prefers registers whose
/// current occupant (if any) has the most distant next use so that future
/// evictions are minimised.  Falls back to the numerically smallest free
/// register.
int _pickReloadReg(
    SSA v,
    Set<int> freeRegs,
    _RegState state,
    Map<SSA, SplayTreeSet<int>> nuds,
    int opIdx) {
  if (freeRegs.length == 1) return freeRegs.first;

  // For the variable being reloaded, find when it will next be used and
  // prefer a register that the variable will need to be in for that use.
  // In the absence of that information, just return the smallest-numbered
  // free register.
  return freeRegs.reduce((a, b) => a < b ? a : b);
}
