import 'package:control_flow_graph/control_flow_graph.dart';

/// Defines an SSA operation in a program's [BasicBlock]. The operation must
/// specify which variables it reads from and writes to.
abstract class Operation {
  /// The set of variables that are written to by this operation.
  SSA? get writesTo => null;

  /// The set of variables that are read from by this operation.
  Set<SSA> get readsFrom => {};

  /// Ordered machine operands, preserving repeated input positions.
  List<SSA> get operands => readsFrom.toList();

  /// Rebuilds machine operands after allocation. Operations with positional
  /// duplicates must override this to retain distinct register assignments.
  Operation copyWithOperands({SSA? writesTo, List<SSA>? operands}) =>
      copyWith(writesTo: writesTo, readsFrom: operands?.toSet());

  /// The basic type of the operation, if it represents one. Used for various
  /// optimizations and transformations.
  OpType get type => const UnknownOp();

  /// Creates a copy of this operation with the given [writesTo] and [readsFrom]
  /// variables.
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom});

  /// Whether an unused result can be discarded without observable effects.
  ///
  /// Pure operations must not mutate state, perform I/O, throw, or affect
  /// control flow. Reading mutable state is not sufficient to justify other
  /// transformations such as common-subexpression elimination. Operations
  /// are conservatively effectful unless they explicitly opt in.
  bool get isPure => false;

  /// Whether this operation transfers control and must end its block.
  bool get isTerminator => false;

  /// Whether this operation is rematerializable. Rematerializable operations
  /// can be recomputed on-the-fly and do not need to be spilled to memory.
  bool get isRematerializable => false;
}

/// Defines a function parameter already present in a physical register.
/// These definitions must precede executable operations in the entry block.
class RegisterInput extends Operation {
  RegisterInput(this.target, this.register);
  final SSA target;
  final int register;
  @override
  SSA get writesTo => target;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      RegisterInput(writesTo ?? target, register);
}

/// A phi node operation in a program's [BasicBlock]. Phi nodes are used to
/// resolve variable assignments in control flow graphs.
/// Typically you should not create phi nodes directly, but use the
/// [ControlFlowGraph.insertPhiNodes] method instead.
class PhiNode extends Operation {
  /// Creates a new phi node operation with the given [target] and [sources].
  PhiNode(this.target, this.sources, {Map<int, SSA>? incoming})
      : incoming = incoming ?? {};

  /// Reaching value on each incoming predecessor edge.
  final Map<int, SSA> incoming;

  /// The target variable of this phi node.
  final SSA target;

  /// The set of source variables of this phi node.
  final Set<SSA> sources;

  @override
  bool get isPure => true;

  @override
  Set<SSA> get readsFrom => sources;

  @override
  SSA? get writesTo => target;

  @override
  String toString() {
    return '$target = φ(${sources.join(', ')})';
  }

  @override
  bool operator ==(Object other) {
    return other is PhiNode &&
        target == other.target &&
        sources.difference(other.sources).isEmpty;
  }

  @override
  int get hashCode => target.hashCode ^ sources.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    final replacements = readsFrom == null
        ? <SSA, SSA>{}
        : Map<SSA, SSA>.fromIterables(sources, readsFrom);
    return PhiNode(writesTo ?? target, readsFrom ?? sources, incoming: {
      for (final entry in incoming.entries)
        entry.key: replacements[entry.value] ?? entry.value
    });
  }
}

/// Placeholder for a spill operation in a program's [BasicBlock]. Spill nodes
/// are used to move variables from registers to memory.
class SpillNode extends Operation {
  final SSA target;

  SpillNode(this.target);

  @override
  SSA? get writesTo => null;

  @override
  OpType get type => const Noop();

  @override
  String toString() {
    return 'spill $target';
  }

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    throw UnimplementedError('Cannot change target of spill op');
  }
}

/// Placeholder for a reload operation in a program's [BasicBlock]. Reload nodes
/// are used to move variables from memory to registers.
class ReloadNode extends Operation {
  final SSA target;

  ReloadNode(this.target);

  @override
  SSA? get writesTo => null;

  @override
  OpType get type => const Noop();

  @override
  String toString() {
    return 'reload $target';
  }

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    throw UnimplementedError('Cannot change target of reload op');
  }
}

/// Swaps the physical register contents of two SSA variables in place.
/// Both variables must share at least one [RegisterGroup] parent (i.e. belong
/// to the same [RegType]) for a swap to be legal.
class SwapOp extends Operation {
  final SSA a;
  final SSA b;

  SwapOp(this.a, this.b);

  @override
  Set<SSA> get readsFrom => {a, b};

  @override
  SSA? get writesTo => null;

  @override
  OpType get type => AssignmentOp.assign;

  @override
  String toString() => 'swap $a, $b';

  @override
  bool operator ==(Object other) =>
      other is SwapOp && a == other.a && b == other.b;

  @override
  int get hashCode => a.hashCode ^ b.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    final reads = readsFrom?.toList();
    return SwapOp(reads?[0] ?? a, reads?[1] ?? b);
  }
}

class Assign extends Operation {
  final SSA target;
  final SSA source;

  Assign(this.target, this.source);

  @override
  bool get isPure => true;

  @override
  Set<SSA> get readsFrom => {source};

  @override
  SSA? get writesTo => target;

  @override
  OpType get type => AssignmentOp.assign;

  @override
  String toString() {
    return '$target = $source';
  }

  @override
  bool operator ==(Object other) {
    return other is Assign && target == other.target && source == other.source;
  }

  @override
  int get hashCode => target.hashCode ^ source.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return Assign(writesTo ?? target, readsFrom?.single ?? source);
  }
}

class ParallelCopy extends Operation {
  final Set<(SSA target, SSA source)> copies = {};

  @override
  Set<SSA> get readsFrom => copies.map((copy) => copy.$2).toSet();

  @override
  SSA? get writesTo => null;

  @override
  OpType get type => AssignmentOp.assign;

  @override
  String toString() {
    return '<pc> ${copies.map((copy) => '${copy.$1} = ${copy.$2}').join(', ')}';
  }

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    throw UnimplementedError('Cannot change target of parallel copy op');
  }
}

/// Represents the basic types of operations that can be performed in a program.
/// These types are used for various optimizations and transformations.
interface class OpType {}

class UnknownOp implements OpType {
  const UnknownOp();
}

/// An operation type that does nothing.
class Noop implements OpType {
  /// Creates a new noop operation type.
  const Noop();
}

/// An operation type that represents arithmetic operations.
enum ArithmeticOp implements OpType {
  add,
  subtract,
  multiply,
  divide,
  modulo,
}

/// An operation type that represents assignment operations.
enum AssignmentOp implements OpType {
  assign,
  assignIndirect,
  addAssign(ArithmeticOp.add),
  subtractAssign(ArithmeticOp.subtract),
  multiplyAssign(ArithmeticOp.multiply),
  divideAssign(ArithmeticOp.divide),
  moduloAssign(ArithmeticOp.modulo);

  /// Creates a new assignment operation type with the given [inner] operation.
  const AssignmentOp([this.inner]);

  /// The inner operation type of this assignment operation. For example,
  /// [addAssign] has an inner operation type of [ArithmeticOp.add].
  final OpType? inner;
}

/// An operation type that represents bitwise operations.
enum BitwiseOp implements OpType { and, or, xor, shiftLeft, shiftRight, not }

/// An operation type that represents comparison operations.
enum ComparisonOp implements OpType {
  equal,
  notEqual,
  lessThan,
  lessThanOrEqual,
  greaterThan,
  greaterThanOrEqual,
}

/// An operation type that represents logical operations.
enum LogicalOp implements OpType {
  and,
  or,
  not,
}

/// An operation type that represents unary operations.
enum UnaryOp implements OpType {
  negate,
}

enum CollectionOp implements OpType {
  indexInto,
  slice,
  length,
  add,
  remove,
  contains,
  clear,
}

enum CallOp implements OpType { call }
