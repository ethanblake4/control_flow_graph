import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

import 'sample_ir.dart';

void main() {
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

    test('Allocate registers', () {
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
    });
  });
}
