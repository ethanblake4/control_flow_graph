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
      expect(cfg[4]!.code[0], PhiNode(SSA('z', 4), {SSA('z', 2), SSA('z', 3)}));
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

    test('Query livein', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      final block = cfg[2]!;
      final i = cfg.findSSAVariable(block, 'i');
      final x = cfg.findSSAVariable(block, 'x');
      expect(cfg.isLiveIn(i, block), true);
      expect(cfg.isLiveIn(x, block), true);

      final block2 = cfg[3]!;
      final i2 = cfg.findSSAVariable(block2, 'i');
      final x2 = cfg.findSSAVariable(block2, 'x');
      expect(cfg.isLiveIn(i2, block2), false);
      expect(cfg.isLiveIn(x2, block2), true);
    });

    test('Query liveout', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      final block = cfg[2]!;
      final i = cfg.findSSAVariable(block, 'i');
      final x = cfg.findSSAVariable(block, 'x');
      expect(cfg.isLiveOut(i, block), true);
      expect(cfg.isLiveOut(x, block), true);

      final block2 = cfg[3]!;
      final i2 = cfg.findSSAVariable(block2, 'i');
      final x2 = cfg.findSSAVariable(block2, 'x');
      expect(cfg.isLiveOut(i2, block2), false);
      expect(cfg.isLiveOut(x2, block2), false);
    });

    test('Remove phi nodes', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removePhiNodes((l, r) => Assign(l, r));
      expect(() => print(cfg), prints('''
B0:
x₀ = imm 0  
i₀ = imm 0  
i₁ = i₀  
x₁ = x₀
→ (B1)

B1:
n = imm 10  
@branch = i₁ < n
→ (B2, B3)

B2:
x₂ = x₁ + i₁  
@1 = imm 1  
i₂ = i₁ + @1  
i₁ = i₂  
x₁ = x₂
→ (B1)

B3:
return x₁\n
'''));
    });
  });

  group('Complex CFG', () {
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([
          LoadImmediate(SSA('a'), 0),
          LoadImmediate(SSA('b'), 0),
        ], label: 'c1'))
        .then(BasicBlock([
          LoadImmediate(SSA('a'), 2),
        ], label: 'c2'))
        .then(BasicBlock([
          LoadImmediate(SSA('b'), 3),
          LessThan(ControlFlowGraph.branch, SSA('a'), SSA('b'))
        ], label: 'c3'))
        .split(
          BasicBlock([
            Assign(SSA('b'), SSA('a')),
          ], label: 'c4'),
          BasicBlock([
            LoadImmediate(SSA('b'), 20),
          ], label: 'c8'),
        )
        .block(0)
        .then(BasicBlock([
          LoadImmediate(SSA('b'), 10),
        ], label: 'c5'))
        .then(BasicBlock([
          LessThan(ControlFlowGraph.branch, SSA('b'), SSA('a')),
        ], label: 'c6'))
        .then(BasicBlock([
          LoadImmediate(SSA('i'), 0),
          Assign(SSA('b'), SSA('i')),
        ], label: 'c7'))
        .commit()
        .block(1)
        .then(BasicBlock([
          LoadImmediate(SSA('i'), 0),
          Assign(SSA('b'), SSA('i')),
        ], label: 'c9'))
        .then(BasicBlock([
          LessThan(ControlFlowGraph.branch, SSA('b'), SSA('i')),
        ], label: 'c10'))
        .build();

    cfg.link(cfg['c6']!, cfg['c5']!);
    cfg.link(cfg['c7']!, cfg['c2']!);
    cfg.link(cfg['c9']!, cfg['c6']!);
    cfg.link(cfg['c10']!, cfg['c8']!);
    cfg.link(cfg['c2']!, BasicBlock([], label: 'c11'));

    test('Find globals', () {
      expect(cfg.globals, {
        'a': {0, 1},
        'b': {0, 3, 2, 8, 7, 4, 5},
        'i': {8, 7},
      });
    });

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

    test('Insert phi nodes', () {
      cfg.insertPhiNodes();
    });

    test('Convert to semi-pruned SSA', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      cfg.computeSemiPrunedSSA();
    });

    test('Remove phi nodes', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removePhiNodes((l, r) => Assign(l, r));
    });
  });
}
