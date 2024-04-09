import 'package:control_flow_graph/src/cfg.dart';
import 'package:control_flow_graph/src/ssa.dart';

/// Defines an SSA operation in a program's [BasicBlock]. The operation must
/// specify which variables it reads from and writes to.
class Operation {
  /// The set of variables that are written to by this operation.
  SSA? get writesTo => null;

  /// The set of variables that are read from by this operation.
  Set<SSA> get readsFrom => {};
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
}
