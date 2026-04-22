import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:test/test.dart';

import 'sample_instruction_set.dart';
import 'sample_ir.dart';

void main() {
  _forLoopGroup(2);
  _forLoopGroup(3);
  _forLoopImmediateGroup();
}

void _forLoopGroup(int registerLimit) {
  // -------------------------------------------------------------------------
  // Expected strings that differ between register limits.
  // -------------------------------------------------------------------------

  final expectedSpill = registerLimit == 2
      ? '''
B0:
x₀ = imm 0  
i₀ = imm 0
→ (B1)

B1:
i₁ = φ(i₀, i₂)  
x₁ = φ(x₀, x₂)  
spill x₁  
n₁ = imm 11  
@branch = i₁ >= n₁
→ (B2, B3)

B2:
spill n₁  
reload x₁  
x₂ = x₁ + i₁  
spill x₂  
i₂ = i₁ + @1=1  
reload x₂
→ (B1)

B3:
reload x₁  
return x₁\n
'''
      : '''
B0:
x₀ = imm 0  
i₀ = imm 0
→ (B1)

B1:
i₁ = φ(i₀, i₂)  
x₁ = φ(x₀, x₂)  
n₁ = imm 11  
@branch = i₁ >= n₁
→ (B2, B3)

B2:
spill n₁  
x₂ = x₁ + i₁  
i₂ = i₁ + @1=1
→ (B1)

B3:
return x₁\n
''';

  // "Remove empty and unused blocks" produces the same output as "Spill
  // registers" for this CFG (no empty blocks are created by spilling).
  final expectedRemoveEmpty = expectedSpill;

  final expectedPhiRemoval = registerLimit == 2
      ? '''
B0:
x₁ = imm 0  
i₁ = imm 0
→ (B1)

B1:
spill x₁  
n₁ = imm 11  
@branch = i₁ >= n₁
→ (B2, B3)

B2:
spill n₁  
reload x₁  
x₁ = x₁ + i₁  
spill x₁  
i₁ = i₁ + @1=1  
reload x₁
→ (B1)

B3:
reload x₁  
return x₁\n
'''
      : '''
B0:
x₁ = imm 0  
i₁ = imm 0
→ (B1)

B1:
n₁ = imm 11  
@branch = i₁ >= n₁
→ (B2, B3)

B2:
spill n₁  
x₁ = x₁ + i₁  
i₁ = i₁ + @1=1
→ (B1)

B3:
return x₁\n
''';

  // -------------------------------------------------------------------------
  // Group
  // -------------------------------------------------------------------------

  group('Standard for loop ($registerLimit registers)', () {
    var hasSpilled = false;
    var hasRemovedPhi = false;

    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([
          LoadImmediate(SSA('x', type: 0), 0),
          LoadImmediate(SSA('i', type: 0), 0),
        ]))
        .then(BasicBlock([
          LoadImmediate(SSA('n', type: 0), 10),
          LoadImmediate(SSA('n', type: 0), 11),
          GreaterThanOrEqual(
              ControlFlowGraph.branch, SSA('i', type: 0), SSA('n', type: 0))
        ]))
        .split(
          BasicBlock([
            Add(SSA('x', type: 0), SSA('x', type: 0), SSA('i', type: 0)),
            Add(SSA('i', type: 0), SSA('i', type: 0), ImmediateSSA('@1', 1)),
          ]),
          BasicBlock([Return(SSA('x', type: 0))]),
        )
        .build();

    cfg.link(cfg[2]!, cfg[1]!);
    cfg.loops.add(Loop(1, {1, 2}, {(2, 3)}));

    final group0 = RegisterGroup({0, 1, 2});
    cfg.registerRegType(0, RegType(0, 'gpr', {group0}));

    cfg.opCreators.addAll({
      LoadImmediate: Imm.creator,
      LessThan: Ilt.creator,
      GreaterThanOrEqual: Igteq.creator,
      Add: Iadd.creator,
      Return: Ret.creator,
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
@branch = i₁ >= n₁
→ (B2, B3)

B2:
x₂ = x₁ + i₁  
i₂ = i₁ + @1=1
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
@branch = i₁ >= n₁
→ (B2, B3)

B2:
x₂ = x₁ + i₁  
i₂ = i₁ + @1=1
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
      cfg.spillReloadVariables({group0: registerLimit});
      hasSpilled = true;
      expect(() => {print(cfg)}, prints(expectedSpill));
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
        cfg.spillReloadVariables({group0: registerLimit});
      }
      cfg.removeEmptyAndUnusedBlocks();
      expect(() => {print(cfg)}, prints(expectedRemoveEmpty));
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
        cfg.spillReloadVariables({group0: registerLimit});
      }
      cfg.removeEmptyAndUnusedBlocks();
      cfg.removePhiNodes((l, r) => Assign(l, r));
      hasRemovedPhi = true;
      expect(() => print(cfg), prints(expectedPhiRemoval));
    });

    test('Allocate registers', () {
      if (!cfg.inSSAForm && !cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removeUnusedDefines();
      if (!hasSpilled) {
        cfg.spillReloadVariables({group0: registerLimit});
        hasSpilled = true;
      }
      cfg.removeEmptyAndUnusedBlocks();
      if (!hasRemovedPhi) {
        cfg.removePhiNodes((l, r) => Assign(l, r));
        hasRemovedPhi = true;
      }
      cfg.performRegisterAllocation();
      print(cfg);

      // Every non-@ writesTo must be AllocatedSSA.
      // Every non-@branch readsFrom must be AllocatedSSA (regular) or
      // ImmediateSSA (@N numeric immediates).
      for (final blockId in cfg.allLiveIn.keys) {
        for (final op in cfg[blockId]!.code) {
          final wt = op.writesTo;
          if (wt != null && !wt.name.startsWith('@')) {
            expect(wt, isA<AllocatedSSA>(),
                reason: 'writesTo of "$op" should be AllocatedSSA');
          }
          for (final r in op.readsFrom) {
            if (r.name == '@branch') continue;
            if (r.name.startsWith('@')) {
              expect(r, isA<ImmediateSSA>(),
                  reason:
                      'immediate operand "$r" of "$op" should be ImmediateSSA');
            } else {
              expect(r, isA<AllocatedSSA>(),
                  reason: 'operand "$r" of "$op" should be AllocatedSSA');
            }
          }
        }
      }
    });

    test('Assemble to instructions', () {
      if (!cfg.inSSAForm && !cfg.hasPhiNodes) {
        cfg.insertPhiNodes();
      }
      if (!cfg.inSSAForm) {
        cfg.computeSemiPrunedSSA();
      }
      cfg.removeUnusedDefines();
      if (!hasSpilled) {
        cfg.spillReloadVariables({group0: registerLimit});
        hasSpilled = true;
      }
      cfg.removeEmptyAndUnusedBlocks();
      if (!hasRemovedPhi) {
        cfg.removePhiNodes((l, r) => Assign(l, r));
        hasRemovedPhi = true;
      }
      cfg.performRegisterAllocation();

      final result = cfg.assembleToInstructions(
        AssemblerConfig<ContextData>(
          contextData: ContextData(),
          onSpill: (v, slot, ctx) => Stloc(v.register, slot),
          onReload: (v, slot, ctx) => Ldloc(v.register, slot),
          onMove: (target, source, ctx) => Mov(target.register, source.register),
          onSwap: (a, b, ctx) => Xchg(a.register, b.register),
          onJump: (targetBlockId, ctx) => Jmp(targetBlockId),
        ),
      );

      // All four blocks must be present.
      expect(result.keys, containsAll([0, 1, 2, 3]));

      // B0 must load two immediates.
      expect(result[0]!.whereType<Imm>(), hasLength(2));

      // B1 must contain an Ilt or IltImm for the loop condition.
      final b1 = result[1]!;
      expect(
        b1.any((i) => i is Igteqj || i is IgteqjImm),
        isTrue,
        reason: 'B1 should contain a greater-than-or-equal comparison',
      );

      // B2 must contain an add instruction.
      final b2 = result[2]!;
      expect(
        b2.any((i) => i is Iadd || i is IaddImm),
        isTrue,
        reason: 'B2 should contain an add instruction',
      );

      // B3 must return.
      expect(result[3]!, anyElement(isA<Ret>()));

      if (registerLimit == 2) {
        // With only 2 registers, spills and reloads must appear somewhere.
        final all = result.values.expand((e) => e).toList();
        expect(all.whereType<Stloc>(), isNotEmpty,
            reason: 'Expected spill instructions with 2 registers');
        expect(all.whereType<Ldloc>(), isNotEmpty,
            reason: 'Expected reload instructions with 2 registers');
      }

      // Pretty-print the assembled output for diagnostic purposes.
      for (final entry in result.entries) {
        print('--- Block ${entry.key} ---');
        for (final instr in entry.value) {
          print(instr);
        }
      }
    });
  });
}

/// For-loop variant where the loop bound is an immediate value rather than a
/// variable.  This exercises [IgteqjImm] and exposes a register-allocation
/// bug: the [Igteq.creator] variants declare [arguments: [0, 1]] for the
/// branch case even when the right-hand operand is an [ImmediateSSA], causing
/// the allocator to attempt to assign a physical register to the immediate.
void _forLoopImmediateGroup() {
  group('For loop with immediate bound', () {
    var hasSpilled = false;
    var hasRemovedPhi = false;

    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock([
          LoadImmediate(SSA('x', type: 0), 0),
          LoadImmediate(SSA('i', type: 0), 0),
        ]))
        .then(BasicBlock([
          GreaterThanOrEqual(ControlFlowGraph.branch, SSA('i', type: 0),
              ImmediateSSA('@n', 11)),
        ]))
        .split(
          BasicBlock([
            Add(SSA('x', type: 0), SSA('x', type: 0), SSA('i', type: 0)),
            Add(SSA('i', type: 0), SSA('i', type: 0), ImmediateSSA('@1', 1)),
          ]),
          BasicBlock([Return(SSA('x', type: 0))]),
        )
        .build();

    cfg.link(cfg[2]!, cfg[1]!);
    cfg.loops.add(Loop(1, {1, 2}, {(2, 3)}));

    final group0 = RegisterGroup({0, 1, 2});
    cfg.registerRegType(0, RegType(0, 'gpr', {group0}));

    cfg.opCreators.addAll({
      LoadImmediate: Imm.creator,
      GreaterThanOrEqual: Igteq.creator,
      Add: Iadd.creator,
      Return: Ret.creator,
    });

    test('Allocate registers', () {
      cfg.insertPhiNodes();
      cfg.computeSemiPrunedSSA();
      cfg.removeUnusedDefines();
      cfg.spillReloadVariables({group0: 2});
      hasSpilled = true;
      cfg.removeEmptyAndUnusedBlocks();
      cfg.removePhiNodes((l, r) => Assign(l, r));
      hasRemovedPhi = true;
      cfg.performRegisterAllocation();
      print(cfg);

      // Every writesTo that isn't a sentinel must be AllocatedSSA.
      // Every readsFrom that isn't a sentinel or immediate must be AllocatedSSA.
      for (final blockId in cfg.allLiveIn.keys) {
        for (final op in cfg[blockId]!.code) {
          final wt = op.writesTo;
          if (wt != null && !wt.name.startsWith('@')) {
            expect(wt, isA<AllocatedSSA>(),
                reason: 'writesTo of "$op" should be AllocatedSSA');
          }
          for (final r in op.readsFrom) {
            if (r.name == '@branch') continue;
            if (r.name.startsWith('@')) {
              expect(r, isA<ImmediateSSA>(),
                  reason:
                      'immediate operand "$r" of "$op" should be ImmediateSSA');
            } else {
              expect(r, isA<AllocatedSSA>(),
                  reason: 'operand "$r" of "$op" should be AllocatedSSA');
            }
          }
        }
      }
    });

    test('Assemble to instructions', () {
      if (!cfg.inSSAForm && !cfg.hasPhiNodes) cfg.insertPhiNodes();
      if (!cfg.inSSAForm) cfg.computeSemiPrunedSSA();
      cfg.removeUnusedDefines();
      if (!hasSpilled) {
        cfg.spillReloadVariables({group0: 2});
        hasSpilled = true;
      }
      cfg.removeEmptyAndUnusedBlocks();
      if (!hasRemovedPhi) {
        cfg.removePhiNodes((l, r) => Assign(l, r));
        hasRemovedPhi = true;
      }
      cfg.performRegisterAllocation();

      final result = cfg.assembleToInstructions(
        AssemblerConfig<ContextData>(
          contextData: ContextData(),
          onSpill: (v, slot, ctx) => Stloc(v.register, slot),
          onReload: (v, slot, ctx) => Ldloc(v.register, slot),
          onMove: (target, source, ctx) => Mov(target.register, source.register),
          onSwap: (a, b, ctx) => Xchg(a.register, b.register),
          onJump: (targetBlockId, ctx) => Jmp(targetBlockId),
        ),
      );

      // B1 must use the immediate-operand branch variant.
      final b1 = result[1]!;
      expect(b1.any((i) => i is IgteqjImm), isTrue,
          reason: 'B1 should use IgteqjImm since bound is an immediate');

      // B2 must contain an add and an unconditional jump back to B1.
      final b2 = result[2]!;
      expect(b2.any((i) => i is Iadd || i is IaddImm), isTrue,
          reason: 'B2 should contain an add instruction');
      expect(b2.last, isA<Jmp>(),
          reason: 'B2 should end with an unconditional jump back to B1');
      expect((b2.last as Jmp).blockIndex, equals(1),
          reason: 'B2 jump target should be B1');

      // B3 must return.
      expect(result[3]!, anyElement(isA<Ret>()));

      for (final entry in result.entries) {
        print('--- Block ${entry.key} ---');
        for (final instr in entry.value) {
          print(instr);
        }
      }
    });
  });
}
