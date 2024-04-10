import 'package:control_flow_graph/control_flow_graph.dart';

/// Defines an SSA operation in a program's [BasicBlock]. The operation must
/// specify which variables it reads from and writes to.
abstract class Operation {
  /// The set of variables that are written to by this operation.
  SSA? get writesTo => null;

  /// The set of variables that are read from by this operation.
  Set<SSA> get readsFrom => {};

  /// The basic type of the operation, if it represents one. Used for various
  /// optimizations and transformations.
  OpType get type => const Noop();

  /// Creates a copy of this operation with the given [writesTo] and [readsFrom]
  /// variables.
  Operation copyWith({SSA? writesTo});
}

/// A phi node operation in a program's [BasicBlock]. Phi nodes are used to
/// resolve variable assignments in control flow graphs.
/// Typically you should not create phi nodes directly, but use the
/// [ControlFlowGraph.insertPhiNodes] method instead.
class PhiNode extends Operation {
  /// Creates a new phi node operation with the given [target] and [sources].
  PhiNode(this.target, this.sources);

  /// The target variable of this phi node.
  final SSA target;

  /// The set of source variables of this phi node.
  final Set<SSA> sources;

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
  Operation copyWith({SSA? writesTo}) {
    return PhiNode(writesTo ?? target, sources);
  }
}

/// Represents the basic types of operations that can be performed in a program.
/// These types are used for various optimizations and transformations.
interface class OpType {}

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
