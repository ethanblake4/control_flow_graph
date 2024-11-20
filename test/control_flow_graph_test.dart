import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/types.dart';
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

  group('Standard for loop', () {
    var hasSpilled = false;
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([
          LoadImmediate(SSA('x', type: 0), 0),
          LoadImmediate(SSA('i', type: 0), 0),
        ]))
        .then(BasicBlock([
          LoadImmediate(SSA('n', type: 0), 10),
          LoadImmediate(SSA('n', type: 0), 11),
          LessThan(
              ControlFlowGraph.branch, SSA('i', type: 0), SSA('n', type: 0))
        ]))
        .split(
          BasicBlock([
            Add(SSA('x', type: 0), SSA('x', type: 0), SSA('i', type: 0)),
            LoadImmediate(SSA('@1'), 1),
            Add(SSA('i', type: 0), SSA('i', type: 0), SSA('@1')),
          ]),
          BasicBlock([Return(SSA('x', type: 0))]),
        )
        .build();

    cfg.link(cfg[2]!, cfg[1]!);
    cfg.loops.add(Loop(1, {1, 2}, {(2, 3)}));

    final group0 = RegisterGroup({0, 1});
    cfg.registerRegType(0, RegType(0, 'gpr', {group0}));

    cfg.opCreators.addAll({
      LoadImmediate: Creator<LoadImmediate, void>(variants: {
        Variant(result: 0, arguments: []),
        Variant(result: 1, arguments: []),
        Variant(result: 2, arguments: []),
      }, create: (operation, context) => INoop()),
      LessThan: Creator<LessThan, void>(variants: {
        Variant(result: 0, arguments: [0, 1]),
        Variant(result: 1, arguments: [0, 1])
      }, create: (operation, context) => INoop()),
      Add: Creator<Add, void>(variants: {
        Variant(result: 0, arguments: [0, 1]),
        Variant(result: 2, arguments: [0, 1])
      }, create: (operation, context) => INoop()),
      Return: Creator<Return, void>(variants: {
        Variant(result: null, arguments: [0]),
      }, create: (operation, context) => INoop()),
    });

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
n₀ = imm 10  
n₁ = imm 11  
@branch = i₁ < n₁
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

    test('Run copy propagation', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.runCopyPropagation();
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
      expect(cfg.isLiveIn(SSA('x', version: 0), block), false);

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

    test('Remove unused defines', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removeUnusedDefines();
      expect(() => {print(cfg)}, prints('''
B0:
x₀ = imm 0  
i₀ = imm 0
→ (B1)

B1:
i₁ = φ(i₀, i₂)  
x₁ = φ(x₀, x₂)  
n₁ = imm 11  
@branch = i₁ < n₁
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

    test('Compute global next use distances', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }

      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }

      cfg.removeUnusedDefines();
      print(cfg.nextUseDistances);
    });

    test('Compute register pressure', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }

      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }

      cfg.removeUnusedDefines();
      print(cfg.registerPressure);
    });

    test('Spill registers', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }

      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }

      cfg.removeUnusedDefines();

      cfg.spillReloadVariables({group0: 2});
      hasSpilled = true;
      expect(() => {print(cfg)}, prints('''
B0:
x₀ = imm 0  
i₀ = imm 0
→ (B1)

B1:
i₁ = φ(i₀, i₂)  
x₁ = φ(x₀, x₂)  
spill x₁  
n₁ = imm 11  
@branch = i₁ < n₁
→ (B2, B3)

B2:
spill n₁  
reload x₁  
x₂ = x₁ + i₁  
@1 = imm 1  
spill x₂  
i₂ = i₁ + @1  
reload x₂
→ (B1)

B3:
reload x₁  
return x₁\n
'''));
    });

    test('Remove empty and unused blocks', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removeUnusedDefines();

      if (!hasSpilled) {
        cfg.spillReloadVariables({group0: 2});
      }

      cfg.removeEmptyAndUnusedBlocks();
      expect(() => {print(cfg)}, prints('''
B0:
x₀ = imm 0  
i₀ = imm 0
→ (B1)

B1:
i₁ = φ(i₀, i₂)  
x₁ = φ(x₀, x₂)  
spill x₁  
n₁ = imm 11  
@branch = i₁ < n₁
→ (B2, B3)

B2:
spill n₁  
reload x₁  
x₂ = x₁ + i₁  
@1 = imm 1  
spill x₂  
i₂ = i₁ + @1  
reload x₂
→ (B1)

B3:
reload x₁  
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
      cfg.removeUnusedDefines();
      if (!hasSpilled) {
        cfg.spillReloadVariables({group0: 2});
      }

      cfg.removeEmptyAndUnusedBlocks();
      cfg.removePhiNodes((l, r) => Assign(l, r));
      expect(() => print(cfg), prints('''
B0:
x₁ = imm 0  
i₁ = imm 0
→ (B1)

B1:
spill x₁  
n₁ = imm 11  
@branch = i₁ < n₁
→ (B2, B3)

B2:
spill n₁  
reload x₁  
x₁ = x₁ + i₁  
@1 = imm 1  
spill x₂  
i₁ = i₁ + @1  
reload x₂
→ (B1)

B3:
reload x₁  
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
      expect(() => {print(cfg)}, prints('''
c1(0):
a₀ = imm 0  
b₀ = imm 0
→ (c2(1))

c2(1):
a₁ = φ(a₀, a₂)  
b₁ = φ(b₀, b₁₀)  
a₂ = imm 2
→ (c3(2), c11(10))

c3(2):
b₂ = imm 3  
@branch = a₂ < b₂
→ (c4(3), c8(4))

c11(10):

c4(3):
b₃ = a₂
→ (c5(5))

c8(4):
b₄ = φ(b₂, b₈)  
b₅ = imm 20
→ (c9(8))

c5(5):
b₆ = φ(b₃, b₉)  
b₇ = imm 10
→ (c6(6))

c9(8):
i₀ = imm 0  
b₈ = i₀
→ (c6(6), c10(9))

c6(6):
b₉ = φ(b₇, b₈)  
i₁ = φ(i₀)  
@branch = b₉ < a₂
→ (c5(5), c7(7))

c10(9):
@branch = b₈ < i₀
→ (c8(4))

c7(7):
i₂ = imm 0  
b₁₀ = i₂
→ (c2(1))\n\n
'''));
    });

    bool ranCopyPropagation = false,
        removedUnusedDefines = false,
        removedBlocks = false;

    test('Run copy propagation', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.runCopyPropagation();
      ranCopyPropagation = true;
      expect(() => {print(cfg)}, prints('''
c1(0):
a₀ = imm 0  
b₀ = imm 0
→ (c2(1))

c2(1):
a₁ = φ(a₀, a₂)  
b₁ = φ(b₀, i₂)  
a₂ = imm 2
→ (c3(2))

c3(2):
b₂ = imm 3  
@branch = a₂ < b₂
→ (c4(3), c8(4))

c4(3):
b₃ = a₂
→ (c5(5))

c8(4):
b₄ = φ(b₂, i₀)  
b₅ = imm 20
→ (c9(8))

c5(5):
b₆ = φ(b₉, a₂)  
b₇ = imm 10
→ (c6(6))

c9(8):
i₀ = imm 0  
b₈ = i₀
→ (c6(6))

c6(6):
b₉ = φ(b₇, i₀)  
i₁ = φ(i₀)  
@branch = b₉ < a₂
→ (c5(5), c7(7))

c7(7):
i₂ = imm 0  
b₁₀ = i₂
→ (c2(1))\n\n
'''));
    });

    test('Remove unused defines', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      if (!ranCopyPropagation) {
        cfg.runCopyPropagation();
      }
      cfg.removeUnusedDefines();
      removedUnusedDefines = true;
      expect(() => {print(cfg)}, prints('''
c1(0):
a₀ = imm 0  
b₀ = imm 0
→ (c2(1))

c2(1):
a₂ = imm 2
→ (c3(2))

c3(2):
b₂ = imm 3  
@branch = a₂ < b₂
→ (c4(3), c8(4))

c4(3):

→ (c5(5))

c8(4):

→ (c9(8))

c5(5):
b₇ = imm 10
→ (c6(6))

c9(8):
i₀ = imm 0
→ (c6(6))

c6(6):
b₉ = φ(b₇, i₀)  
@branch = b₉ < a₂
→ (c5(5), c7(7))

c7(7):
i₂ = imm 0
→ (c2(1))\n\n
'''));
    });

    test('Remove empty and unused blocks', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      if (!ranCopyPropagation) {
        cfg.runCopyPropagation();
      }
      if (!removedUnusedDefines) {
        cfg.removeUnusedDefines();
      }
      cfg.removeEmptyAndUnusedBlocks();
      removedBlocks = true;
      expect(() => {print(cfg)}, prints('''
c1(0):
a₀ = imm 0  
b₀ = imm 0
→ (c2(1))

c2(1):
a₂ = imm 2
→ (c3(2))

c3(2):
b₂ = imm 3  
@branch = a₂ < b₂
→ (c5(5), c9(8))

c5(5):
b₇ = imm 10
→ (c6(6))

c9(8):
i₀ = imm 0
→ (c6(6))

c6(6):
b₉ = φ(b₇, i₀)  
@branch = b₉ < a₂
→ (c5(5), c7(7))

c7(7):
i₂ = imm 0
→ (c2(1))\n\n
'''));
    });

    test('Remove phi nodes', () {
      if (!cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      if (!ranCopyPropagation) {
        cfg.runCopyPropagation();
      }
      if (!removedUnusedDefines) {
        cfg.removeUnusedDefines();
      }
      if (!removedBlocks) {
        cfg.removeEmptyAndUnusedBlocks();
      }
      cfg.removePhiNodes((l, r) => Assign(l, r));
      expect(() => print(cfg), prints('''
c1(0):
a₀ = imm 0  
b₀ = imm 0
→ (c2(1))

c2(1):
a₂ = imm 2
→ (c3(2))

c3(2):
b₂ = imm 3  
@branch = a₂ < b₂
→ (c5(5), c9(8))

c5(5):
b₉ = imm 10
→ (c6(6))

c9(8):
b₉ = imm 0
→ (c6(6))

c6(6):
@branch = b₉ < a₂
→ (c5(5), c7(7))

c7(7):
i₂ = imm 0
→ (c2(1))\n\n
'''));
    });
  });
}
