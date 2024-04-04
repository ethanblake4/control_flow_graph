import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

import 'sample_ir.dart';

void main() {
  group('Simple CFG', () {
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

    test('Find globals', () {
      expect(cfg.globals, {
        'z': {1, 2},
      });
    });

    test('Compute dominators', () {
      expect(cfg.dominators[0], 0);
      expect(cfg.dominators[1], 0);
      expect(cfg.dominators[2], 0);
      expect(cfg.dominators[3], 0);
    });

    test('Compute dominator tree', () {
      final tree = cfg.dominatorTree;
      expect(tree.predecessorsOf(0), {0});
      expect(tree.predecessorsOf(0), {0});
      expect(tree.predecessorsOf(0), {0});
      expect(tree.predecessorsOf(0), {0});
    });

    test('Compute DJ-Graph', () {
      expect(cfg.djGraph.predecessorsOf(0), {0});
    });

    test('Compute merge sets', () {
      expect(cfg.mergeSets.containsKey(0), isFalse);
      expect(cfg.mergeSets[1], {3});
      expect(cfg.mergeSets[2], {3});
    });

    test('Insert phi nodes', () {
      cfg.insertPhiNodes();
      expect(cfg[3]!.code[0], equals(PhiNode(SSA('z'), {SSA('z')})));
    });

    test('Convert to semi-pruned SSA', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      cfg.computeSemiPrunedSSA();
      print(cfg);
      expect(cfg[3]!.code[0], PhiNode(SSA('z', 2), {SSA('z', 0), SSA('z', 1)}));
    });
  });

  group('CFG with loop', () {
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
        .merge(BasicBlock([
          LoadImmediate(SSA('c'), 4),
          LessThan(ControlFlowGraph.branch, SSA('z'), SSA('c'))
        ]))
        .merge(BasicBlock([Return(SSA('z'))]))
        .build();

    cfg.link(cfg[3]!, cfg[0]!);

    test('Find globals', () {
      expect(cfg.globals, {
        'z': {1, 2},
      });
    });

    test('Compute dominators', () {
      expect(cfg.dominators[0], 0);
      expect(cfg.dominators[1], 0);
      expect(cfg.dominators[2], 0);
      expect(cfg.dominators[3], 0);
    });

    test('Compute dominator tree', () {
      final tree = cfg.dominatorTree;
      expect(tree.predecessorsOf(0), {0});
      expect(tree.predecessorsOf(1), {0});
      expect(tree.predecessorsOf(2), {0});
      expect(tree.predecessorsOf(3), {0});
    });

    test('Compute DJ-Graph', () {
      expect(cfg.djGraph.getEdge(0, 1)!.value, dEdge);
      expect(cfg.djGraph.getEdge(0, 3)!.value, dEdge);
      expect(cfg.djGraph.getEdge(1, 3)!.value, jEdge);
      expect(cfg.djGraph.getEdge(3, 0)!.value, jEdge);
    });

    test('Compute merge sets', () {
      print(cfg.mergeSets);
      expect(cfg.mergeSets[1], {0, 3});
      expect(cfg.mergeSets[1], {0, 3});
    });

    test('Insert phi nodes', () {
      cfg.insertPhiNodes();
    });

    test('Convert to semi-pruned SSA', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      cfg.computeSemiPrunedSSA();
      expect(cfg[3]!.code[0], PhiNode(SSA('z', 2), {SSA('z', 0), SSA('z', 1)}));
    });
  });

  group('Standard for loop', () {
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([
          LoadImmediate(SSA('x'), 0),
          LoadImmediate(SSA('i'), 0),
        ]))
        .then(BasicBlock([
          LoadImmediate(SSA('n'), 10),
          LessThan(ControlFlowGraph.branch, SSA('i'), SSA('n'))
        ]))
        .split(
          BasicBlock([
            Add(SSA('x'), SSA('x'), SSA('i')),
            LoadImmediate(SSA('@1'), 1),
            Add(SSA('i'), SSA('i'), SSA('@1')),
          ]),
          BasicBlock([Return(SSA('x'))]),
        )
        .build();

    cfg.link(cfg[2]!, cfg[1]!);

    test('Find globals', () {
      expect(cfg.globals, {
        'x': {0, 2},
        'i': {0, 2},
      });
    });

    test('Compute dominators', () {
      expect(cfg.dominators[0], 0);
      expect(cfg.dominators[1], 0);
      expect(cfg.dominators[2], 1);
      expect(cfg.dominators[3], 1);
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
      expect(cfg.djGraph.getEdge(2, 1)!.value, jEdge);
    });

    test('Compute merge sets', () {
      expect(cfg.mergeSets[2], {1});
      expect(cfg.mergeSets[1], {1});
    });

    test('Insert phi nodes', () {
      cfg.insertPhiNodes();
    });

    test('Convert to semi-pruned SSA', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      cfg.computeSemiPrunedSSA();
      expect(() => {print(cfg)}, prints('''
B0:
x₀ = imm 0  
i₀ = imm 0
→ (B1)

B1:
i₁ = φ(i₀, i₂)  
x₁ = φ(x₀, x₂)  
n = imm 10  
@branch = i₁ < n
→ (B2, B3)

B2:
x₂ = x₁ + i₁  
@1 = imm 1  
i₂ = i₁ + @1
→ (B1)

B3:
return x₁\n
'''));
    });

    test('Remove phi nodes', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removePhiNodes((l, r) => Assign(l, r));
      print(cfg);
    });
  });

  group('Complex CFG', () {
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([], label: 'c1'))
        .then(BasicBlock([], label: 'c2'))
        .then(BasicBlock([], label: 'c3'))
        .split(
          BasicBlock([], label: 'c4'),
          BasicBlock([], label: 'c8'),
        )
        .block(0)
        .then(BasicBlock([], label: 'c5'))
        .then(BasicBlock([], label: 'c6'))
        .then(BasicBlock([], label: 'c7'))
        .commit()
        .block(1)
        .then(BasicBlock([], label: 'c9'))
        .then(BasicBlock([], label: 'c10'))
        .build();

    cfg.link(cfg['c6']!, cfg['c5']!);
    cfg.link(cfg['c7']!, cfg['c2']!);
    cfg.link(cfg['c9']!, cfg['c6']!);
    cfg.link(cfg['c10']!, cfg['c8']!);
    cfg.link(cfg['c2']!, BasicBlock([], label: 'c11'));

    test('Compute dominators', () {
      expect(cfg.dominators[cfg.labels['c1']], cfg.labels['c1']);
      expect(cfg.dominators[cfg.labels['c2']], cfg.labels['c1']);
      expect(cfg.dominators[cfg.labels['c11']], cfg.labels['c2']);
      expect(cfg.dominators[cfg.labels['c3']], cfg.labels['c2']);
      expect(cfg.dominators[cfg.labels['c4']], cfg.labels['c3']);
      expect(cfg.dominators[cfg.labels['c8']], cfg.labels['c3']);
      expect(cfg.dominators[cfg.labels['c5']], cfg.labels['c3']);
      expect(cfg.dominators[cfg.labels['c6']], cfg.labels['c3']);
      expect(cfg.dominators[cfg.labels['c7']], cfg.labels['c6']);
      expect(cfg.dominators[cfg.labels['c9']], cfg.labels['c8']);
      expect(cfg.dominators[cfg.labels['c10']], cfg.labels['c9']);
    });

    test('Build DJ-Graph', () {
      expect(cfg.djGraph.getEdge(cfg.labels['c1']!, cfg.labels['c2']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c2']!, cfg.labels['c11']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c2']!, cfg.labels['c3']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c3']!, cfg.labels['c4']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c3']!, cfg.labels['c8']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c3']!, cfg.labels['c5']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c8']!, cfg.labels['c9']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c9']!, cfg.labels['c10']!)!.value,
          dEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c6']!, cfg.labels['c7']!)!.value,
          dEdge);

      expect(cfg.djGraph.getEdge(cfg.labels['c5']!, cfg.labels['c6']!)!.value,
          jEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c6']!, cfg.labels['c5']!)!.value,
          jEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c7']!, cfg.labels['c2']!)!.value,
          jEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c10']!, cfg.labels['c8']!)!.value,
          jEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c4']!, cfg.labels['c5']!)!.value,
          jEdge);
      expect(cfg.djGraph.getEdge(cfg.labels['c9']!, cfg.labels['c6']!)!.value,
          jEdge);
    });

    test('Compute merge sets', () {
      expect(cfg.mergeSets[cfg.labels['c2']], {cfg.labels['c2']});
      expect(cfg.mergeSets[cfg.labels['c3']], {cfg.labels['c2']});
      expect(cfg.mergeSets[cfg.labels['c4']],
          {cfg.labels['c2'], cfg.labels['c5'], cfg.labels['c6']});
      expect(cfg.mergeSets[cfg.labels['c8']], {
        cfg.labels['c2'],
        cfg.labels['c5'],
        cfg.labels['c6'],
        cfg.labels['c8']
      });
      expect(cfg.mergeSets[cfg.labels['c5']],
          {cfg.labels['c2'], cfg.labels['c5'], cfg.labels['c6']});
      expect(cfg.mergeSets[cfg.labels['c6']],
          {cfg.labels['c2'], cfg.labels['c5'], cfg.labels['c6']});
      expect(cfg.mergeSets[cfg.labels['c7']], {cfg.labels['c2']});
      expect(cfg.mergeSets[cfg.labels['c9']], {
        cfg.labels['c2'],
        cfg.labels['c5'],
        cfg.labels['c6'],
        cfg.labels['c8']
      });
      expect(cfg.mergeSets[cfg.labels['c10']], {
        cfg.labels['c2'],
        cfg.labels['c5'],
        cfg.labels['c6'],
        cfg.labels['c8']
      });
    });

    test('Compute merge sets 1000 times', () {
      final c2 = cfg.labels['c2']!;
      final ts = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 1000; i++) {
        cfg.invalidate();
        expect(cfg.mergeSets[c2], {c2});
      }
      print(DateTime.now().millisecondsSinceEpoch - ts);
    });
  });
}
