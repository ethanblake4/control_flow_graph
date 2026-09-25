import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

import 'sample_ir.dart';

void main() {
  test('copies from both predecessors preserve phi edge definitions', () {
    final graph = ControlFlowGraph();
    final root = BasicBlock<Operation>([
      LoadImmediate(SSA('a'), 1),
      LoadImmediate(SSA('b'), 2),
      LessThan(ControlFlowGraph.branch, SSA('a'), SSA('b')),
    ], label: 'root');
    final left = BasicBlock<Operation>([
      Assign(SSA('value'), SSA('a')),
    ], label: 'left');
    final right = BasicBlock<Operation>([
      Assign(SSA('value'), SSA('a')),
    ], label: 'right');
    final join = BasicBlock<Operation>([
      Return(SSA('value')),
    ], label: 'join');
    graph.append(root);
    graph.root = root;
    graph.link(root, left);
    graph.link(root, right);
    graph.link(left, join);
    graph.link(right, join);
    graph.insertPhiNodes();
    graph.computeSemiPrunedSSA();
    validateSSA(graph);

    graph.runCopyPropagation();
    validateSSA(graph);
    final phi = join.code.whereType<PhiNode>().single;
    final a = root.code.first.writesTo!;
    expect(phi.incoming, {left.id: a, right.id: a});
    expect(phi.sources, {a});
    expect(join.code.whereType<Return>().single.value, a);
  });
}
