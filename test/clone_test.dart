import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';
import 'backend_pipeline_test.dart' show Machine, v;

void main() {
  test('clone preserves SSA phase and independent phi operands', () {
    final root = BasicBlock<Operation>([Machine('constant', v('x'), [], 0)]);
    final left = BasicBlock<Operation>([Machine('constant', v('x'), [], 1)]);
    final right = BasicBlock<Operation>([]);
    final end = BasicBlock<Operation>([
      Machine('return', null, [v('x')])
    ]);
    final graph = ControlFlowGraph.builder()
        .root(root)
        .split(left, right)
        .merge(end)
        .build();
    graph.insertPhiNodes();
    graph.computeSemiPrunedSSA();
    final clone = graph.clone();
    expect(clone.inSSAForm, isTrue);
    expect(clone.hasPhiNodes, isTrue);
    final originalPhi = end.code.whereType<PhiNode>().single;
    final clonedPhi = clone[end.id!]!.code.whereType<PhiNode>().single;
    expect(clonedPhi.incoming, originalPhi.incoming);
    clonedPhi.target.version = 99;
    clonedPhi.sources.first.version = 100;
    expect(originalPhi.target.version, isNot(99));
    expect(originalPhi.sources.first.version, isNot(100));
  });

  test('refresh updates SSA metadata without renaming after lowering', () {
    final root = BasicBlock<Operation>([
      Machine('constant', v('x'), [], 1),
      Machine('return', null, [v('x')])
    ]);
    final graph = ControlFlowGraph.builder().root(root).build();
    graph.insertPhiNodes();
    graph.computeSemiPrunedSSA();
    final clone = graph.clone();
    final value = clone.root.code.first.writesTo!;
    clone.root.code[0] = Machine('constant', value.copy(), [], 2);
    clone.refreshSSA();
    expect(clone.defines![value]!.op, same(clone.root.code.first));
    expect(value.version, 0);
    expect(clone.uses![value], hasLength(1));
    expect(clone.hasPhiNodes, isTrue);
  });
}

