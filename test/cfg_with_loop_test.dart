import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

import 'sample_ir.dart';

void main() {
  group('CFG with loop', () {
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([
          LoadImmediate(SSA('z'), 0),
        ]))
        .then(BasicBlock([
          LoadImmediate(SSA('x'), 1),
          LoadImmediate(SSA('y'), 2),
          LessThan(ControlFlowGraph.branch, SSA('x'), SSA('y'))
        ]))
        .split(
          BasicBlock([LoadImmediate(SSA('z'), 3)]),
          BasicBlock([LoadImmediate(SSA('z'), 4)]),
        )
        .merge(BasicBlock([
          LoadImmediate(SSA('c'), 4),
          LessThan(ControlFlowGraph.branch, SSA('z'), SSA('c'))
        ]))
        .merge(BasicBlock([Return(SSA('z'))]))
        .build();

    cfg.link(cfg[4]!, cfg[1]!);

    test('Find globals', () {
      expect(cfg.globals, {
        'z': {0, 2, 3},
      });
    });

    test('Compute dominators', () {
      expect(cfg.dominators[0], 0);
      expect(cfg.dominators[1], 0);
      expect(cfg.dominators[2], 1);
      expect(cfg.dominators[3], 1);
      expect(cfg.dominators[4], 1);
    });

    test('Compute dominator tree', () {
      final tree = cfg.dominatorTree;
      expect(tree.predecessorsOf(0), {0});
      expect(tree.predecessorsOf(1), {0});
      expect(tree.predecessorsOf(2), {1});
      expect(tree.predecessorsOf(3), {1});
    });

    test('Compute DJ-Graph', () {
      expect(cfg.djGraph.getEdge(0, 1)!.value, dEdge);
      expect(cfg.djGraph.getEdge(1, 2)!.value, dEdge);
      expect(cfg.djGraph.getEdge(2, 4)!.value, jEdge);
      expect(cfg.djGraph.getEdge(4, 1)!.value, jEdge);
    });

    test('Compute merge sets', () {
      expect(cfg.mergeSets[1], {1});
      expect(cfg.mergeSets[2], {1, 4});
      expect(cfg.mergeSets[4], {1});
    });

    test('Insert phi nodes', () {
      cfg.insertPhiNodes();
    });

    test('Convert to semi-pruned SSA', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      cfg.computeSemiPrunedSSA();
      expect(
          cfg[4]!.code[0],
          PhiNode(SSA('z', version: 4),
              {SSA('z', version: 2), SSA('z', version: 3)}));
    });
  });
}
