import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

void main() {
  test('equality constraints propagate through phi and copy chains', () {
    final a = SSA('a'), b = SSA('b'), c = SSA('c'), d = SSA('d');
    final constraints = SSAValueConstraints<String>()
      ..equate([a, b, c])
      ..equate([c, d])
      ..constrain(d, 'integer');
    expect(constraints.solve(), {
      a: 'integer',
      b: 'integer',
      c: 'integer',
      d: 'integer',
    });
    expect(() => constraints.constrain(a, 'object'), throwsStateError);
  });

  test('definition lookup follows copies and stops at a copy cycle', () {
    final a = SSA('a'), b = SSA('b'), c = SSA('c');
    final origin = RegisterInput(a, 0);
    final graph = ControlFlowGraph();
    graph.append(BasicBlock<Operation>([
      origin,
      Assign(b, a),
      Assign(c, b),
    ]));
    expect(SSADefinitions(graph).throughCopies(c), same(origin));

    final cycle = ControlFlowGraph();
    cycle.append(BasicBlock<Operation>([Assign(a, b), Assign(b, a)]));
    expect(SSADefinitions(cycle).throughCopies(a), isNull);
  });
}
