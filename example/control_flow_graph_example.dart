import 'package:control_flow_graph/control_flow_graph.dart';

void main() {
  /// Create a control flow graph (CFG) for the following code:
  /// ```dart
  /// var x = 1, y = 2;
  /// var z = x < y ? 3 : 4;
  /// return z;
  /// ```
  final cfg = ControlFlowGraph.builder()
      .root(BasicBlock([
        LoadImmediate(SSA('x'), 1),
        LoadImmediate(SSA('y'), 2),
        LessThan(ControlFlowGraph.branch, SSA('x'), SSA('y'))
      ]))
      .split(
        BasicBlock([LoadImmediate(SSA('z'), 3)]),
        BasicBlock([LoadImmediate(SSA('z'), 4)]),
      )
      .merge(BasicBlock([Return(SSA('z'))]))
      .build();

  print(cfg.globals); // {z: {1, 2}}
  print(cfg.dominators[2]); // 0
  print(cfg.dominatorTree.predecessorsOf(1)); // {0}
  print(cfg.djGraph.predecessorsOf(0)); // {0}
  print(cfg.mergeSets[1]); // {3}

  cfg.insertPhiNodes();
  print(cfg[3]!.code[0]); // z = φ(z)

  cfg.computeSemiPrunedSSA();
  print(cfg[3]!.code[0]); // z₂ = φ(z₀, z₁)
}

// Sample intermediate representation (IR) classes

final class LoadImmediate extends Operation {
  final SSA target;
  final int value;

  LoadImmediate(this.target, this.value);

  @override
  SSA? get writesTo => target;

  @override
  String toString() => '$target = imm $value';
}

final class LessThan extends Operation {
  final SSA target;
  final SSA left;
  final SSA right;

  LessThan(this.target, this.left, this.right);

  @override
  Set<SSA> get readsFrom => {left, right};

  @override
  SSA get writesTo => target;

  @override
  String toString() => '$target = $left < $right';
}

final class Return extends Operation {
  final SSA value;

  Return(this.value);

  @override
  Set<SSA> get readsFrom => {value};

  @override
  String toString() => 'return $value';
}
