import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

void main() {
  test('unreachable predecessors are removed before dominator computation', () {
    final root = BasicBlock<Operation>([], label: 'root');
    final join = BasicBlock<Operation>([], label: 'join');
    final unreachable = BasicBlock<Operation>([], label: 'unreachable');
    final cfg = ControlFlowGraph.builder().root(root).then(join).build();
    cfg.link(unreachable, join);
    final joinId = join.id;
    cfg.removeUnreachableBlocks();
    expect(cfg['unreachable'], isNull);
    expect(cfg[unreachable.id!], isNull);
    expect(cfg['join']!.id, joinId);
    expect(cfg.graph.predecessorsOf(join.id!), [root.id]);
    cfg.insertPhiNodes();
    cfg.computeSemiPrunedSSA();
    expect(cfg.inSSAForm, isTrue);
  });

  test('pruning after SSA is rejected', () {
    final cfg =
        ControlFlowGraph.builder().root(BasicBlock<Operation>([])).build();
    cfg.insertPhiNodes();
    expect(cfg.removeUnreachableBlocks, throwsStateError);
  });
}
