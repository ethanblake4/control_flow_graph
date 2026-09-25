import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/operation.dart'
    show PhiNode, ReloadNode, SpillNode;
import 'package:test/test.dart';

import 'sample_instruction_set.dart';
import 'sample_ir.dart';

void main() {
  group('complex control-flow graph', () {
    test('computes globals and immediate dominators across nested cycles', () {
      final cfg = _buildComplexGraph();

      expect(cfg.globals, {
        'a': {0, 1},
        'b': {0, 2, 3, 4, 5, 7, 8},
        'i': {7, 8},
      });
      expect(_dominatorsByLabel(cfg), {
        'c1': 'c1',
        'c2': 'c1',
        'c3': 'c2',
        'c4': 'c3',
        'c8': 'c3',
        'c5': 'c3',
        'c6': 'c3',
        'c7': 'c6',
        'c9': 'c8',
        'c10': 'c9',
        'c11': 'c2',
      });
    });

    test('distinguishes dominator and join edges', () {
      final cfg = _buildComplexGraph();

      _expectDjEdges(cfg, dEdge, [
        ('c1', 'c2'),
        ('c2', 'c3'),
        ('c2', 'c11'),
        ('c3', 'c4'),
        ('c3', 'c8'),
        ('c3', 'c5'),
        ('c8', 'c9'),
        ('c9', 'c10'),
        ('c6', 'c7'),
      ]);
      _expectDjEdges(cfg, jEdge, [
        ('c4', 'c5'),
        ('c5', 'c6'),
        ('c6', 'c5'),
        ('c7', 'c2'),
        ('c9', 'c6'),
        ('c10', 'c8'),
      ]);
      expect(cfg.mergeSets[cfg.labels['c2']], {cfg.labels['c2']});
      expect(cfg.mergeSets[cfg.labels['c8']], {
        cfg.labels['c2'],
        cfg.labels['c5'],
        cfg.labels['c6'],
        cfg.labels['c8'],
      });
      expect(cfg.mergeSets[cfg.labels['c10']], {
        cfg.labels['c2'],
        cfg.labels['c5'],
        cfg.labels['c6'],
        cfg.labels['c8'],
      });
    });

    test('SSA keeps predecessor-specific values for used joins', () {
      final cfg = _ssaComplexGraph();

      _expectPhi(cfg, 'c6', 'b', predecessors: ['c5', 'c9']);
      expect(_operations(cfg).whereType<PhiNode>(), hasLength(1));
      expect(cfg.defines, contains(_phiTarget(cfg, 'c6', 'b')));
      expect(cfg.ssaGraph.vertices, isNotEmpty);
    });

    test('copy propagation removes aliases and DCE respects effectful loads',
        () {
      final cfg = _optimizedComplexGraph(removeEmptyBlocks: false);

      expect(_operations(cfg).whereType<Assign>(), isEmpty);
      expect(_loads(cfg, 'c1').map((op) => op.value), [0, 0]);
      expect(_loads(cfg, 'c2').map((op) => op.value), [2]);
      expect(_loads(cfg, 'c3').map((op) => op.value), [3]);
      expect(_loads(cfg, 'c5').map((op) => op.value), [10]);
      expect(_loads(cfg, 'c9').map((op) => op.value), [0]);
      expect(_loads(cfg, 'c7').map((op) => op.value), [0]);

      final remainingPhis = _operations(cfg).whereType<PhiNode>().toList();
      expect(remainingPhis, hasLength(1));
      expect(remainingPhis.single.target.name, 'b');
      expect(cfg[6]!.code.whereType<LessThan>(), hasLength(1));
    });

    test('keeps an empty conditional arm so successor order stays intact', () {
      final cfg = _optimizedComplexGraph();

      expect(
          cfg.graph.vertices, unorderedEquals(List.generate(11, (id) => id)));
      expect(cfg[3]!.code, isEmpty);
      expect(cfg.graph.successorsOf(2).toList(), [3, 4]);
      expect(cfg.graph.successorsOf(3), [5]);
      expect(cfg.graph.successorsOf(4), [8]);
      expect(cfg.graph.successorsOf(6), unorderedEquals([5, 7]));
      expect(cfg.graph.successorsOf(7), [1]);
    });

    test('removes a linear empty bridge', () {
      final root = BasicBlock<Operation>([
        LoadImmediate(SSA('value'), 1),
      ]);
      final bridge = BasicBlock<Operation>([]);
      final exit = BasicBlock<Operation>([Return(SSA('value'))]);
      final cfg =
          ControlFlowGraph.builder().root(root).then(bridge).then(exit).build();
      cfg.insertPhiNodes();
      cfg.computeSemiPrunedSSA();

      cfg.removeEmptyAndUnusedBlocks();

      expect(cfg.graph.vertices, unorderedEquals([root.id, exit.id]));
      expect(cfg.graph.successorsOf(root.id!), [exit.id]);
      expect(cfg[exit.id!]!.code, hasLength(1));
    });

    test('spilling, phi lowering, allocation, and assembly agree', () {
      final cfg = _optimizedComplexGraph();
      cfg.spillReloadVariables({_registers: 3});

      cfg.removePhiNodes(Assign.new);
      expect(_operations(cfg).whereType<PhiNode>(), isEmpty);
      cfg.performRegisterAllocation();
      _expectAllocated(cfg);

      final allocatedOperations = _reachableBlockIds(cfg)
          .expand((blockId) => cfg[blockId]!.code)
          .toList();
      final allocatedSpills = allocatedOperations.whereType<SpillNode>().length;
      final allocatedReloads =
          allocatedOperations.whereType<ReloadNode>().length;

      final program = _assemble(cfg);
      expect(program.keys, unorderedEquals(_reachableBlockIds(cfg)));
      final outerBranch = program[2]!.whereType<Iltj>().single;
      final innerBranch = program[6]!.whereType<Iltj>().single;
      expect(outerBranch.blockIndex, cfg.graph.successorsOf(2).elementAt(1));
      expect(innerBranch.blockIndex, cfg.graph.successorsOf(6).elementAt(1));

      final instructions = program.values.expand((block) => block).toList();
      expect(instructions.whereType<Stloc>(), hasLength(allocatedSpills));
      expect(instructions.whereType<Ldloc>(), hasLength(allocatedReloads));
    });
  });
}

final _registers = RegisterGroup({0, 1, 2, 3});

ControlFlowGraph _buildComplexGraph() {
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
        LessThan(ControlFlowGraph.branch, SSA('a'), SSA('b')),
      ], label: 'c3'))
      .split(
        BasicBlock([Assign(SSA('b'), SSA('a'))], label: 'c4'),
        BasicBlock([LoadImmediate(SSA('b'), 20)], label: 'c8'),
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

  cfg.loops
    ..add(Loop(1, {1, 2, 3, 4, 5, 6, 7, 8, 9}, {(1, 10)}))
    ..add(Loop(4, {4, 8, 9}, {(8, 6)}));
  cfg.registerRegType(-1, RegType(0, 'gpr', {_registers}));
  cfg.registerRegType(0, RegType(0, 'gpr', {_registers}));
  cfg.opCreators.addAll({
    LoadImmediate: Imm.creator,
    LessThan: Ilt.creator,
  });
  return cfg;
}

ControlFlowGraph _ssaComplexGraph() {
  final cfg = _buildComplexGraph()..insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  return cfg;
}

ControlFlowGraph _optimizedComplexGraph({bool removeEmptyBlocks = true}) {
  final cfg = _ssaComplexGraph();
  cfg.runCopyPropagation();
  cfg.removeUnusedDefines();
  if (removeEmptyBlocks) cfg.removeEmptyAndUnusedBlocks();
  return cfg;
}

Map<String, String> _dominatorsByLabel(ControlFlowGraph cfg) {
  final labelsById = {
    for (final entry in cfg.labels.entries) entry.value: entry.key
  };
  return {
    for (final entry in cfg.labels.entries)
      entry.key: labelsById[cfg.dominators[entry.value]]!,
  };
}

void _expectDjEdges(
  ControlFlowGraph cfg,
  int kind,
  Iterable<(String, String)> edges,
) {
  for (final (source, target) in edges) {
    expect(
      cfg.djGraph.getEdge(cfg.labels[source]!, cfg.labels[target]!)!.value,
      kind,
      reason: '$source -> $target has the wrong DJ edge kind',
    );
  }
}

void _expectPhi(
  ControlFlowGraph cfg,
  String block,
  String variable, {
  required Iterable<String> predecessors,
}) {
  final phi = cfg[block]!
      .code
      .whereType<PhiNode>()
      .singleWhere((candidate) => candidate.target.name == variable);
  expect(
    phi.incoming.keys,
    unorderedEquals(predecessors.map((label) => cfg.labels[label]!)),
  );
  expect(phi.sources.map((source) => source.name), everyElement(variable));
}

SSA _phiTarget(ControlFlowGraph cfg, String block, String variable) =>
    cfg[block]!
        .code
        .whereType<PhiNode>()
        .singleWhere((phi) => phi.target.name == variable)
        .target;

Iterable<Operation> _operations(ControlFlowGraph cfg) sync* {
  for (final blockId in cfg.graph.vertices) {
    yield* cfg[blockId]!.code;
  }
}

Set<int> _reachableBlockIds(ControlFlowGraph cfg) {
  final reachable = <int>{};
  final pending = <int>[cfg.root.id!];
  while (pending.isNotEmpty) {
    final block = pending.removeLast();
    if (reachable.add(block)) {
      pending.addAll(cfg.graph.successorsOf(block));
    }
  }
  return reachable;
}

Iterable<LoadImmediate> _loads(ControlFlowGraph cfg, String label) =>
    cfg[label]!.code.whereType<LoadImmediate>();

void _expectAllocated(ControlFlowGraph cfg) {
  for (final blockId in _reachableBlockIds(cfg)) {
    for (final operation in cfg[blockId]!.code) {
      final output = operation.writesTo;
      if (output != null && output != ControlFlowGraph.branch) {
        expect(output, isA<AllocatedSSA>(),
            reason: '$operation has no output register');
      }
      for (final input in operation.readsFrom) {
        expect(input, anyOf(isA<AllocatedSSA>(), isA<ImmediateSSA>()),
            reason: '$operation has an unallocated input');
      }
    }
  }
}

Map<int, List<Instruction>> _assemble(ControlFlowGraph cfg) {
  return cfg.assembleToInstructions(
    AssemblerConfig<ContextData>(
      contextData: ContextData(),
      onSpill: (value, slot, context) => Stloc(value.register, slot),
      onReload: (value, slot, context) => Ldloc(value.register, slot),
      onMove: (target, source, context) =>
          Mov(target.register, source.register),
      onSwap: (a, b, context) => Xchg(a.register, b.register),
      onJump: (target, context) => Jmp(target),
    ),
  );
}
