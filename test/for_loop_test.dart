import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/operation.dart'
    show PhiNode, ReloadNode, SpillNode;
import 'package:test/test.dart';

import 'sample_instruction_set.dart';
import 'sample_ir.dart';

void main() {
  group('for-loop analysis', () {
    test('finds loop globals, dominators, and merge points', () {
      final cfg = _buildForLoop();

      expect(cfg.globals, {
        'x': {0, 2},
        'i': {0, 2},
      });
      expect(cfg.dominators, {0: 0, 1: 0, 2: 1, 3: 1});
      expect(cfg.dominatorTree.predecessorsOf(2), {1});
      expect(cfg.dominatorTree.predecessorsOf(3), {1});
      expect(cfg.djGraph.getEdge(0, 1)!.value, dEdge);
      expect(cfg.djGraph.getEdge(1, 2)!.value, dEdge);
      expect(cfg.djGraph.getEdge(2, 1)!.value, jEdge);
      expect(cfg.mergeSets[1], {1});
      expect(cfg.mergeSets[2], {1});
    });

    test('SSA joins both loop-carried values', () {
      final cfg = _buildForLoop()..insertPhiNodes();
      cfg.computeSemiPrunedSSA();

      final phis = cfg[1]!.code.whereType<PhiNode>().toList();
      expect(phis.map((phi) => phi.target.name), unorderedEquals(['x', 'i']));
      for (final phi in phis) {
        expect(phi.incoming.keys, unorderedEquals([0, 2]));
        expect(phi.sources.map((source) => source.name), {phi.target.name});
        expect(phi.sources, hasLength(2));
      }

      final body = cfg[2]!.code;
      expect(body.whereType<Subtract>(), hasLength(1));
      expect(body.whereType<Add>(), hasLength(2));
    });

    test('liveness follows the loop-carried accumulator and index', () {
      final cfg = _ssaForLoop();
      final body = cfg[2]!;
      final exit = cfg[3]!;
      final i = cfg.findSSAVariable(body, 'i');
      final x = cfg.findSSAVariable(body, 'x');

      expect(cfg.isLiveIn(i, body), isTrue);
      expect(cfg.isLiveIn(x, body), isTrue);
      expect(cfg.isLiveOut(i, body), isTrue);
      expect(cfg.isLiveOut(x, body), isTrue);
      expect(cfg.isLiveIn(cfg.findSSAVariable(exit, 'i'), exit), isFalse);
      expect(cfg.isLiveIn(cfg.findSSAVariable(exit, 'x'), exit), isTrue);
      expect(cfg.allLiveOut[exit.id], isEmpty);
    });

    test('dead-code elimination retains operations not declared pure', () {
      final cfg = _ssaForLoop();
      cfg.removeUnusedDefines();

      final bounds = cfg[1]!.code.whereType<LoadImmediate>().toList();
      expect(bounds.map((op) => op.value), [10, 11]);
      expect(cfg[2]!.code.whereType<Subtract>(), hasLength(1),
          reason: 'the subtraction feeds both following additions');
      expect(cfg.nextUseDistances[2], isNotEmpty);
      expect(cfg.registerPressure[2]![_registers], greaterThan(2));
    });
  });

  for (final registerLimit in [2, 3]) {
    group('for-loop pipeline with $registerLimit registers', () {
      test('inserts only spills required by the pressure limit', () {
        final cfg = _optimizedForLoop();
        cfg.spillReloadVariables({_registers: registerLimit});

        final operations = _operations(cfg);
        final spills = operations.whereType<SpillNode>().toList();
        final reloads = operations.whereType<ReloadNode>().toList();
        if (registerLimit == 2) {
          expect(spills, isNotEmpty);
          expect(reloads, isNotEmpty);
          expect(spills.map((op) => op.target.name), contains('x'));
          expect(reloads.map((op) => op.target.name), everyElement('x'));
        } else {
          expect(spills, isEmpty);
          expect(reloads, isEmpty);
        }
      });

      test('lowers phis, allocates values, and emits instructions', () {
        final cfg = _loweredForLoop(registerLimit);

        expect(_operations(cfg).whereType<PhiNode>(), isEmpty);
        _expectAllocated(cfg);

        final program = _assemble(cfg);
        expect(program.keys, containsAll([0, 1, 2, 3]));
        expect(program[0]!.whereType<Imm>(), hasLength(2));
        expect(program[1]!, anyElement(anyOf(isA<Igteqj>(), isA<IgteqjImm>())));
        expect(program[2]!, anyElement(isA<Isub>()));
        expect(program[2]!, anyElement(anyOf(isA<Iadd>(), isA<IaddImm>())));
        expect(program[2]!.last, isA<Jmp>());
        expect((program[2]!.last as Jmp).blockIndex, 1);
        expect(program[3]!, anyElement(isA<Ret>()));
      });
    });
  }

  for (final bound in [0, 1, 2, 11, 25]) {
    test('immediate-bound loop returns the sum below $bound', () {
      final cfg = _buildImmediateLoop(bound);
      cfg.insertPhiNodes();
      cfg.computeSemiPrunedSSA();
      cfg.removeUnusedDefines();
      cfg.spillReloadVariables({_registers: 2});
      cfg.removeEmptyAndUnusedBlocks();
      cfg.removePhiNodes(Assign.new);
      cfg.performRegisterAllocation();

      _expectAllocated(cfg);
      final program = _assemble(cfg);
      final branch = program[1]!.whereType<IgteqjImm>().single;
      expect(branch.immediate, bound);
      expect(branch.blockIndex, 3);
      expect(_run(program), bound * (bound - 1) ~/ 2);
    });
  }
}

final _registers = RegisterGroup({0, 1, 2});

ControlFlowGraph _buildForLoop() {
  final cfg = ControlFlowGraph.builder()
      .root(BasicBlock([
        LoadImmediate(SSA('x', type: 0), 0),
        LoadImmediate(SSA('i', type: 0), 0),
      ]))
      .then(BasicBlock([
        LoadImmediate(SSA('n', type: 0), 10),
        LoadImmediate(SSA('n', type: 0), 11),
        GreaterThanOrEqual(
          ControlFlowGraph.branch,
          SSA('i', type: 0),
          SSA('n', type: 0),
        ),
      ]))
      .split(
        BasicBlock([
          Subtract(SSA('i', type: 0), SSA('i', type: 0), SSA('x', type: 0)),
          Add(SSA('x', type: 0), SSA('x', type: 0), SSA('i', type: 0)),
          Add(SSA('i', type: 0), SSA('i', type: 0), ImmediateSSA('@1', 1)),
        ]),
        BasicBlock([Return(SSA('x', type: 0))]),
      )
      .build();
  cfg.link(cfg[2]!, cfg[1]!);
  _configure(cfg);
  return cfg;
}

ControlFlowGraph _buildImmediateLoop(int bound) {
  final cfg = ControlFlowGraph.builder()
      .root(BasicBlock([
        LoadImmediate(SSA('x', type: 0), 0),
        LoadImmediate(SSA('i', type: 0), 0),
      ]))
      .then(BasicBlock([
        GreaterThanOrEqual(
          ControlFlowGraph.branch,
          SSA('i', type: 0),
          ImmediateSSA('@limit', bound),
        ),
      ]))
      .split(
        BasicBlock([
          Add(SSA('x', type: 0), SSA('x', type: 0), SSA('i', type: 0)),
          Add(SSA('i', type: 0), SSA('i', type: 0), ImmediateSSA('@one', 1)),
        ]),
        BasicBlock([Return(SSA('x', type: 0))]),
      )
      .build();
  cfg.link(cfg[2]!, cfg[1]!);
  _configure(cfg);
  return cfg;
}

void _configure(ControlFlowGraph cfg) {
  cfg.loops.add(Loop(1, {1, 2}, {(2, 3)}));
  cfg.registerRegType(0, RegType(0, 'gpr', {_registers}));
  cfg.opCreators.addAll({
    LoadImmediate: Imm.creator,
    GreaterThanOrEqual: Igteq.creator,
    Add: Iadd.creator,
    Subtract: Isub.creator,
    Return: Ret.creator,
  });
}

ControlFlowGraph _ssaForLoop() {
  final cfg = _buildForLoop()..insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  return cfg;
}

ControlFlowGraph _optimizedForLoop() {
  final cfg = _ssaForLoop();
  cfg.removeUnusedDefines();
  return cfg;
}

ControlFlowGraph _loweredForLoop(int registerLimit) {
  final cfg = _optimizedForLoop();
  cfg.spillReloadVariables({_registers: registerLimit});
  cfg.removeEmptyAndUnusedBlocks();
  cfg.removePhiNodes(Assign.new);
  cfg.performRegisterAllocation();
  return cfg;
}

Iterable<Operation> _operations(ControlFlowGraph cfg) sync* {
  for (final blockId in cfg.graph.vertices) {
    yield* cfg[blockId]!.code;
  }
}

void _expectAllocated(ControlFlowGraph cfg) {
  for (final operation in _operations(cfg)) {
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

int _run(Map<int, List<Instruction>> program) {
  final registers = List<int>.filled(3, 0);
  final slots = <int, int>{};
  final order = program.keys.toList();
  var block = order.first;

  for (var budget = 0; budget < 1000; budget++) {
    int? next;
    for (final instruction in program[block]!) {
      switch (instruction) {
        case Imm(:final reg, :final value):
          registers[reg] = value;
        case Iadd(:final target, :final left, :final right):
          registers[target] = registers[left] + registers[right];
        case IaddImm(:final target, :final left, :final immediate):
          registers[target] = registers[left] + immediate;
        case Stloc(:final register, :final slotIndex):
          slots[slotIndex] = registers[register];
        case Ldloc(:final register, :final slotIndex):
          registers[register] = slots[slotIndex]!;
        case Mov(:final target, :final source):
          registers[target] = registers[source];
        case Xchg(:final a, :final b):
          final old = registers[a];
          registers[a] = registers[b];
          registers[b] = old;
        case IgteqjImm(:final left, :final immediate, :final blockIndex):
          if (registers[left] >= immediate) next = blockIndex;
        case Jmp(:final blockIndex):
          next = blockIndex;
        case Ret(:final reg):
          return registers[reg];
        default:
          throw StateError('Unsupported test instruction: $instruction');
      }
    }
    block = next ?? order[order.indexOf(block) + 1];
  }
  throw StateError('Program did not terminate');
}
