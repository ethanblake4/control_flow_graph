import 'package:control_flow_graph/control_flow_graph.dart';

import 'sample_ir.dart';

class ContextData {}

extension FirstImmediateIndex on Set<SSA> {
  int? firstImmediateIndex() {
    for (var i = 0; i < length; i++) {
      if (elementAt(i) is ImmediateSSA) {
        return i;
      }
    }
    return null;
  }
}

/// Load immediate 16-bit integer value into a register
class Imm extends Instruction {
  final int reg;
  final int value;

  Imm(this.reg, this.value);

  static final creator = Creator<LoadImmediate, ContextData>(
    variants: {
      Variant(result: 0),
      Variant(result: 1),
    },
    create: (op, context) => Imm(op.writesTo!.alloc.register, op.value),
  );

  @override
  toString() => 'imm r$reg, $value';
}

class Iadd extends Instruction {
  final int target;
  final int left;
  final int right;

  Iadd(this.target, this.left, this.right);

  static final creator = Creator<Add, ContextData>(
      variants: {
        Variant(result: 0, arguments: [0, 1]),
        Variant(result: 1, arguments: [0, 1]),
        Variant(result: 1, arguments: [1, 0]),
        Variant(result: 0, arguments: [1, 0]),
      },
      create: (op, context) {
        final immediateIndex = op.readsFrom.firstImmediateIndex();
        final otherIndex = immediateIndex == 0 ? 1 : 0;
        return immediateIndex != null
            ? IaddImm(
                op.writesTo!.alloc.register,
                op.readsFrom.elementAt(otherIndex).alloc.register,
                (op.readsFrom.elementAt(immediateIndex).imm).value as int,
              )
            : Iadd(
                op.writesTo!.alloc.register,
                op.readsFrom.elementAt(0).alloc.register,
                op.readsFrom.elementAt(1).alloc.register,
              );
      });

  @override
  toString() => 'iadd r$target, r$left, r$right';
}

class IaddImm extends Instruction {
  final int target;
  final int left;
  final int immediate;

  IaddImm(this.target, this.left, this.immediate);

  @override
  toString() => 'iadd r$target, r$left, $immediate';
}

/// Integer less-than comparison that writes the boolean result into a register.
class Ilt extends Instruction {
  final int target;
  final int left;
  final int right;

  Ilt(this.target, this.left, this.right);

  static final creator = Creator<LessThan, ContextData>(
    variants: {
      // Register-result variants (Ilt / IltImm).
      Variant(result: 0, arguments: [0, 1]),
      Variant(result: 1, arguments: [0, 1]),
      // Branch variants (Iltj / IltjImm) — @branch is not a physical register.
      Variant(result: null, arguments: [0, 1]),
      Variant(result: null, arguments: [1, 0]),
    },
    create: (op, context) {
      final immediate = op.readsFrom.elementAt(1) is ImmediateSSA;
      final isBranch = op.writesTo == ControlFlowGraph.branch;
      if (isBranch) {
        final trueBlockId = context.successorBlockIds.length > 1
            ? context.successorBlockIds[1]
            : 0;
        return immediate
            ? IltjImm(
                op.readsFrom.elementAt(0).alloc.register,
                (op.readsFrom.elementAt(1).imm).value as int,
                trueBlockId,
              )
            : Iltj(
                op.readsFrom.elementAt(0).alloc.register,
                op.readsFrom.elementAt(1).alloc.register,
                trueBlockId,
              );
      } else {
        return immediate
            ? IltImm(
                op.writesTo!.alloc.register,
                op.readsFrom.elementAt(0).alloc.register,
                (op.readsFrom.elementAt(1).imm).value as int,
              )
            : Ilt(
                op.writesTo!.alloc.register,
                op.readsFrom.elementAt(0).alloc.register,
                op.readsFrom.elementAt(1).alloc.register,
              );
      }
    },
  );

  @override
  toString() => 'ilt r$target, r$left, r$right';
}

/// Integer less-than comparison with an immediate right-hand operand,
/// writing the boolean result into a register.
class IltImm extends Instruction {
  final int target;
  final int left;
  final int immediate;

  IltImm(this.target, this.left, this.immediate);

  @override
  toString() => 'ilt r$target, r$left, $immediate';
}

/// Integer less-than comparison that branches to [blockIndex] if the result
/// is true.  Triggered when the [LessThan] operation writes to
/// [ControlFlowGraph.branch].
class Iltj extends Instruction {
  final int left;
  final int right;
  final int blockIndex;

  Iltj(this.left, this.right, [this.blockIndex = 0]);

  @override
  toString() => 'iltj r$left, r$right, #$blockIndex';
}

/// Integer less-than comparison with an immediate right-hand operand that
/// branches to [blockIndex] if the result is true.
class IltjImm extends Instruction {
  final int left;
  final int immediate;
  final int blockIndex;

  IltjImm(this.left, this.immediate, [this.blockIndex = 0]);

  @override
  toString() => 'iltj r$left, $immediate, #$blockIndex';
}

/// Integer greater-than-or-equal comparison that writes the boolean result
/// into a register.
class Igteq extends Instruction {
  final int target;
  final int left;
  final int right;

  Igteq(this.target, this.left, this.right);

  static final creator = Creator<GreaterThanOrEqual, ContextData>(
    variants: {
      Variant(result: 0, arguments: [0, 1]),
      Variant(result: 1, arguments: [0, 1]),
      Variant(result: null, arguments: [0, 1]),
      Variant(result: null, arguments: [1, 0]),
    },
    create: (op, context) {
      final immediate = op.readsFrom.elementAt(1) is ImmediateSSA;
      final isBranch = op.writesTo == ControlFlowGraph.branch;
      if (isBranch) {
        final takenBlockId = context.successorBlockIds.length > 1
            ? context.successorBlockIds[1]
            : 0;
        return immediate
            ? IgteqjImm(
                op.readsFrom.elementAt(0).alloc.register,
                (op.readsFrom.elementAt(1).imm).value as int,
                takenBlockId,
              )
            : Igteqj(
                op.readsFrom.elementAt(0).alloc.register,
                op.readsFrom.elementAt(1).alloc.register,
                takenBlockId,
              );
      } else {
        return immediate
            ? IgteqImm(
                op.writesTo!.alloc.register,
                op.readsFrom.elementAt(0).alloc.register,
                (op.readsFrom.elementAt(1).imm).value as int,
              )
            : Igteq(
                op.writesTo!.alloc.register,
                op.readsFrom.elementAt(0).alloc.register,
                op.readsFrom.elementAt(1).alloc.register,
              );
      }
    },
  );

  @override
  toString() => 'igteq r$target, r$left, r$right';
}

/// Integer greater-than-or-equal comparison with an immediate right-hand
/// operand, writing the boolean result into a register.
class IgteqImm extends Instruction {
  final int target;
  final int left;
  final int immediate;

  IgteqImm(this.target, this.left, this.immediate);

  @override
  toString() => 'igteq r$target, r$left, $immediate';
}

/// Integer greater-than-or-equal comparison that branches to [blockIndex] if
/// the result is true.  Triggered when the [GreaterThanOrEqual] operation
/// writes to [ControlFlowGraph.branch].
class Igteqj extends Instruction {
  final int left;
  final int right;
  final int blockIndex;

  Igteqj(this.left, this.right, [this.blockIndex = 0]);

  @override
  toString() => 'igteqj r$left, r$right, #$blockIndex';
}

/// Integer greater-than-or-equal comparison with an immediate right-hand
/// operand that branches to [blockIndex] if the result is true.
class IgteqjImm extends Instruction {
  final int left;
  final int immediate;
  final int blockIndex;

  IgteqjImm(this.left, this.immediate, [this.blockIndex = 0]);

  @override
  toString() => 'igteqj r$left, $immediate, #$blockIndex';
}

/// Unconditional jump to [blockIndex].  Synthesised by the assembler when a
/// block's sole successor is not the next block in the layout order.
class Jmp extends Instruction {
  final int blockIndex;

  Jmp(this.blockIndex);

  @override
  toString() => 'jmp #$blockIndex';
}

/// Return from the current function, passing the value in [reg] to the caller.
class Ret extends Instruction {
  final int reg;

  Ret(this.reg);

  static final creator = Creator<Return, ContextData>(
    variants: {
      Variant(result: null, arguments: [0]),
    },
    create: (op, context) => Ret(op.readsFrom.single.alloc.register),
  );

  @override
  toString() => 'ret r$reg';
}

/// Store a register to a typed local slot (spill).
class Stloc extends Instruction {
  final int register;
  final int slotIndex;

  Stloc(this.register, this.slotIndex);

  @override
  toString() => 'stloc r$register, [$slotIndex]';
}

/// Load a typed local slot into a register (reload).
class Ldloc extends Instruction {
  final int register;
  final int slotIndex;

  Ldloc(this.register, this.slotIndex);

  @override
  toString() => 'ldloc r$register, [$slotIndex]';
}

/// Copy one register into another (register move).
class Mov extends Instruction {
  final int target;
  final int source;

  Mov(this.target, this.source);

  @override
  toString() => 'mov r$target, r$source';
}

/// Exchange the contents of two registers (register swap).
class Xchg extends Instruction {
  final int a;
  final int b;

  Xchg(this.a, this.b);

  @override
  toString() => 'xchg r$a, r$b';
}
