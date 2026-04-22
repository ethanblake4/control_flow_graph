import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/instructions/context.dart';
import 'package:control_flow_graph/src/operation.dart';
import 'package:control_flow_graph/src/types.dart';

/// Callback type for emitting a spill (store to local slot) instruction.
///
/// [variable] is the allocated SSA variable being spilled (its [AllocatedSSA.register]
/// is the physical register being stored from).  [slotIndex] is the unique
/// per-[SSA.type] slot index assigned to this variable.  [context] carries the
/// user-supplied context data passed to [AssemblerConfig].
typedef SpillCallback<C> = Instruction Function(
    AllocatedSSA variable, int slotIndex, AssembleContext<C> context);

/// Callback type for emitting a reload (load from local slot) instruction.
///
/// [variable] is the allocated SSA variable being reloaded (its
/// [AllocatedSSA.register] is the physical register being loaded into).
/// [slotIndex] is the same slot index that was assigned when this variable was
/// originally spilled.
typedef ReloadCallback<C> = Instruction Function(
    AllocatedSSA variable, int slotIndex, AssembleContext<C> context);

/// Callback type for emitting a register-to-register move instruction.
///
/// Corresponds to a synthesised [Assign] operation inserted by the register
/// allocator to shuffle values between physical registers.
typedef MoveCallback<C> = Instruction Function(
    AllocatedSSA target, AllocatedSSA source, AssembleContext<C> context);

/// Callback type for emitting a register swap instruction.
///
/// Corresponds to a synthesised [SwapOp] operation inserted by the register
/// allocator.  Both [a] and [b] must belong to the same [RegType].
typedef SwapCallback<C> = Instruction Function(
    AllocatedSSA a, AllocatedSSA b, AssembleContext<C> context);

/// Callback type for emitting an unconditional jump instruction.
///
/// Called when a block's sole CFG successor is not the next block in the
/// layout order, meaning a fall-through is impossible and an explicit jump
/// is required to reach it.  [targetBlockId] is the ID of the target block.
typedef JumpCallback<C> = Instruction Function(
    int targetBlockId, AssembleContext<C> context);

/// Configuration object passed to [ControlFlowGraph.assembleToInstructions].
///
/// Provides user-defined callbacks for the five categories of synthesised
/// operations emitted by the register allocator:
///
/// * **spill** – store a register to a typed local slot (`stloc N`).
/// * **reload** – load a typed local slot into a register (`ldloc N`).
/// * **move** – copy one register into another (the two have the same
///   [RegType]).
/// * **swap** – exchange the contents of two registers of the same [RegType].
/// * **jump** – unconditional branch to a block whose ID is not the next in
///   the layout order.
///
/// [contextData] is threaded through every [InstructionCreator.createInstruction]
/// call and the synthesised-op callbacks as [AssembleContext.data].
class AssemblerConfig<C> {
  const AssemblerConfig({
    required this.contextData,
    required this.onSpill,
    required this.onReload,
    this.onMove,
    this.onSwap,
    this.onJump,
  });

  /// Arbitrary user data made available in every callback via
  /// [AssembleContext.data].
  final C contextData;

  /// Called once per [SpillNode] in the post-allocation IR.
  ///
  /// [slotIndex] is a zero-based index within the bank of slots for the
  /// variable's [SSA.type].  The same [slotIndex] will be supplied to the
  /// corresponding [onReload] call(s).
  final SpillCallback<C> onSpill;

  /// Called once per [ReloadNode] in the post-allocation IR.
  final ReloadCallback<C> onReload;

  /// Called once per synthesised [Assign] (register move).  If `null`,
  /// moves are silently dropped.
  final MoveCallback<C>? onMove;

  /// Called once per synthesised [SwapOp] (register swap).  If `null`,
  /// swaps are silently dropped.
  final SwapCallback<C>? onSwap;

  /// Called when a block's sole successor is not the next block in the layout
  /// order, requiring an explicit unconditional jump.  If `null`, the jump is
  /// silently omitted (useful when the caller controls block ordering
  /// externally).
  final JumpCallback<C>? onJump;
}

/// Assembles a post-register-allocation [ControlFlowGraph] into concrete
/// [Instruction] lists, one per basic block, keyed by block ID.
///
/// Call this after [ControlFlowGraph.performRegisterAllocation].  Every
/// [SSA] operand in the IR must be either an [AllocatedSSA] or an
/// [ImmediateSSA] at this point; the assembler will throw [StateError] if it
/// encounters an unallocated variable.
///
/// **Slot assignment**
///
/// Each spilled SSA variable is assigned a unique *local-slot index* within
/// the bank of slots for its [SSA.type].  Slot indices start at 0 and are
/// allocated in the order the corresponding [SpillNode]s are encountered
/// during a breadth-first traversal of the CFG.  The same index is reused for
/// every [ReloadNode] that reloads the same variable (matched by SSA name +
/// version).
Map<int, List<Instruction>> assembleBlocksToInstructions<C>(
  Map<int, BasicBlock> blocks,
  Iterable<int> blockOrder,
  Map<Type, InstructionCreator> opCreators,
  AssemblerConfig<C> config, {
  CFG? graph,
}) {
  final context = AssembleContext(config.contextData);

  // slot key: SSA name+version (strips physical register so spill and reload
  // for the same logical variable always map to the same slot).
  final slotAssignments = <_SlotKey, int>{};

  // Next available slot index per typeId.
  final slotCountPerType = <int, int>{};

  int nextSlot(int typeId) {
    final idx = slotCountPerType[typeId] ?? 0;
    slotCountPerType[typeId] = idx + 1;
    return idx;
  }

  AllocatedSSA _requireAllocated(SSA ssa, Operation op) {
    if (ssa is AllocatedSSA) return ssa;
    throw StateError(
        'Expected AllocatedSSA for operand "$ssa" of "$op" but got ${ssa.runtimeType}. '
        'Did you call performRegisterAllocation()?');
  }

  final result = <int, List<Instruction>>{};
  final blockOrderList = blockOrder.toList();

  for (var blockIndex = 0; blockIndex < blockOrderList.length; blockIndex++) {
    final blockId = blockOrderList[blockIndex];
    final block = blocks[blockId]!;
    final instructions = <Instruction>[];

    // Update the context with this block's identity and successor list so that
    // instruction creators (e.g. conditional-branch instructions) can resolve
    // target block IDs without needing a separate lookup.
    context.currentBlockId = blockId;
    context.successorBlockIds = graph == null
        ? const []
        : graph.successorsOf(blockId).toList();

    for (final op in block.code) {
      // ---- SpillNode --------------------------------------------------------
      if (op is SpillNode) {
        final v = _requireAllocated(op.target, op);
        final key = _SlotKey(v.name, v.version);
        final slot = slotAssignments.putIfAbsent(key, () => nextSlot(v.type));
        instructions.add(config.onSpill(v, slot, context));
        continue;
      }

      // ---- ReloadNode -------------------------------------------------------
      if (op is ReloadNode) {
        final v = _requireAllocated(op.target, op);
        final key = _SlotKey(v.name, v.version);
        // If a reload is seen before a corresponding spill (e.g. after
        // rematerialisation), assign a fresh slot.
        final slot = slotAssignments.putIfAbsent(key, () => nextSlot(v.type));
        instructions.add(config.onReload(v, slot, context));
        continue;
      }

      // ---- Assign (register move) ------------------------------------------
      if (op is Assign) {
        final onMove = config.onMove;
        if (onMove != null) {
          final target = _requireAllocated(op.target, op);
          final source = _requireAllocated(op.source, op);
          instructions.add(onMove(target, source, context));
        }
        continue;
      }

      // ---- SwapOp (register swap) ------------------------------------------
      if (op is SwapOp) {
        final onSwap = config.onSwap;
        if (onSwap != null) {
          final a = _requireAllocated(op.a, op);
          final b = _requireAllocated(op.b, op);
          instructions.add(onSwap(a, b, context));
        }
        continue;
      }

      // ---- PhiNode (should be absent by assembly time) ---------------------
      if (op is PhiNode) {
        // Phi nodes must be removed before assembly; skip defensively.
        continue;
      }

      // ---- Regular user-defined operation ----------------------------------
      final creator = opCreators[op.runtimeType];
      if (creator != null) {
        instructions.add(creator.createInstruction(op, context));
      }
    }

    // ---- Unconditional jump (if needed) ------------------------------------
    // If this block has exactly one successor and it is not the next block in
    // the layout, a fall-through is impossible — emit an explicit jump.
    final onJump = config.onJump;
    if (onJump != null && context.successorBlockIds.length == 1) {
      final successorId = context.successorBlockIds.first;
      final nextBlockId = blockIndex + 1 < blockOrderList.length
          ? blockOrderList[blockIndex + 1]
          : null;
      if (successorId != nextBlockId) {
        instructions.add(onJump(successorId, context));
      }
    }

    result[blockId] = instructions;
  }

  return result;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// A map key that identifies an SSA variable by name + version, ignoring
/// the physical register (if any).
class _SlotKey {
  const _SlotKey(this.name, this.version);

  final String name;
  final int version;

  @override
  bool operator ==(Object other) =>
      other is _SlotKey && name == other.name && version == other.version;

  @override
  int get hashCode => name.hashCode ^ version.hashCode;
}
