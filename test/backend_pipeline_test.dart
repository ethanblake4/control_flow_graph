import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

SSA v(String name) => SSA(name, type: 0);

class Machine extends Operation {
  final String kind;
  final SSA? output;
  final List<SSA> inputs;
  final int immediate;
  Machine(this.kind, this.output, [this.inputs = const [], this.immediate = 0]);
  @override
  SSA? get writesTo => output;
  @override
  Set<SSA> get readsFrom => inputs.toSet();
  @override
  bool get isTerminator => kind == 'branch' || kind == 'return';
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    final replacements = readsFrom == null
        ? <SSA, SSA>{}
        : Map<SSA, SSA>.fromIterables(this.readsFrom, readsFrom);
    return Machine(kind, writesTo ?? output,
        [for (final input in inputs) replacements[input] ?? input], immediate);
  }
}

class Insn extends Instruction {
  final String kind;
  final List<int> operands;
  Insn(this.kind, this.operands);
  @override
  String toString() => "$kind $operands";
}

Map<int, List<Instruction>> lower(ControlFlowGraph cfg) {
  final regs = RegisterGroup({for (var i = 0; i < 32; i++) i});
  cfg.registerRegType(0, RegType(0, 'object', {regs}));
  cfg.opCreators[Machine] = Creator<Machine, void>(
      variants: {},
      create: (op, ctx) {
        return Insn(op.kind, [
          if (op.output != null && op.output != ControlFlowGraph.branch)
            op.output!.alloc.register,
          for (final input in op.inputs) input.alloc.register,
          if (op.kind == 'constant') op.immediate,
          if (op.kind == 'branch') ...ctx.successorBlockIds,
        ]);
      });
  cfg.insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  cfg.removeUnusedDefines();
  cfg.spillReloadVariables({regs: 32});
  cfg.removePhiNodes(Assign.new);
  cfg.performRegisterAllocation();
  return cfg.assembleToInstructions(AssemblerConfig<void>(
    contextData: null,
    onSpill: (v, slot, ctx) => Insn('spill', [v.register, slot]),
    onReload: (v, slot, ctx) => Insn('reload', [v.register, slot]),
    onMove: (a, b, ctx) => Insn('move', [a.register, b.register]),
    onSwap: (a, b, ctx) => Insn('swap', [a.register, b.register]),
    onJump: (target, ctx) => Insn('jump', [target]),
  ));
}

int run(Map<int, List<Instruction>> program, int entry) {
  final regs = List<int>.filled(32, 0), slots = <int, int>{};
  final order = program.keys.toList();
  var block = entry;
  for (var budget = 0; budget < 1000; budget++) {
    int? next;
    for (final instruction in program[block]!.cast<Insn>()) {
      final a = instruction.operands;
      switch (instruction.kind) {
        case 'constant':
          regs[a[0]] = a[1];
        case 'add':
          regs[a[0]] = regs[a[1]] + regs[a[2]];
        case 'less':
          regs[a[0]] = regs[a[1]] < regs[a[2]] ? 1 : 0;
        case 'move':
          regs[a[0]] = regs[a[1]];
        case 'swap':
          final old = regs[a[0]];
          regs[a[0]] = regs[a[1]];
          regs[a[1]] = old;
        case 'spill':
          slots[a[1]] = regs[a[0]];
        case 'reload':
          regs[a[0]] = slots[a[1]]!;
        case 'branch':
          next = regs[a[0]] != 0 ? a[1] : a[2];
        case 'jump':
          next = a[0];
        case 'return':
          return regs[a[0]];
      }
    }
    block = next ?? order[order.indexOf(block) + 1];
  }
  throw StateError('Execution did not terminate');
}

void main() {
  test('branch phi accepts definition before immediate predecessor', () {
    for (final condition in [0, 1]) {
      final root = BasicBlock<Operation>([
        Machine('constant', v('x'), [], 10),
        Machine('constant', v('condition'), [], condition),
        Machine('branch', ControlFlowGraph.branch, [v('condition')]),
      ]);
      final left = BasicBlock<Operation>([Machine('constant', v('x'), [], 20)]);
      final right = BasicBlock<Operation>([]);
      final end = BasicBlock<Operation>([
        Machine('return', null, [v('x')])
      ]);
      final cfg = ControlFlowGraph.builder()
          .root(root)
          .split(left, right)
          .merge(end)
          .build();
      expect(run(lower(cfg), root.id!), condition == 1 ? 20 : 10);
    }
  });

  test('loop phi and register edges preserve accumulator', () {
    final root = BasicBlock<Operation>([
      Machine('constant', v('i'), [], 0),
      Machine('constant', v('sum'), [], 0),
      Machine('constant', v('one'), [], 1),
      Machine('constant', v('limit'), [], 5),
    ]);
    final header = BasicBlock<Operation>([
      Machine('less', v('condition'), [v('i'), v('limit')]),
      Machine('branch', ControlFlowGraph.branch, [v('condition')]),
    ]);
    final body = BasicBlock<Operation>([
      Machine('add', v('sum'), [v('sum'), v('i')]),
      Machine('add', v('i'), [v('i'), v('one')]),
    ]);
    final exit = BasicBlock<Operation>([
      Machine('return', null, [v('sum')])
    ]);
    final cfg = ControlFlowGraph.builder()
        .root(root)
        .then(header)
        .split(body, exit)
        .build();
    cfg.link(body, header);
    expect(run(lower(cfg), root.id!), 10);
  });

  test('dead sequential results do not exhaust unconstrained registers', () {
    final root = BasicBlock<Operation>([
      for (var i = 0; i < 80; i++) Machine('constant', v('v$i'), [], i),
      Machine('return', null, [v('v79')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    expect(run(lower(cfg), root.id!), 79);
  });
  test('critical edges preserve both branch outcomes', () {
    for (final condition in [0, 1]) {
      final root = BasicBlock<Operation>([
        Machine('constant', v('x'), [], 10),
        Machine('constant', v('condition'), [], condition),
        Machine('branch', ControlFlowGraph.branch, [v('condition')]),
      ]);
      final update =
          BasicBlock<Operation>([Machine('constant', v('x'), [], 20)]);
      final end = BasicBlock<Operation>([
        Machine('return', null, [v('x')])
      ]);
      final cfg =
          ControlFlowGraph.builder().root(root).then(update).then(end).build();
      cfg.link(root, end);
      expect(run(lower(cfg), root.id!), condition == 1 ? 20 : 10);
      expect(cfg.graph.vertices.length, 4);
    }
  });

  test('copy leaves its source available for subsequent uses', () {
    final root = BasicBlock<Operation>([
      Machine('constant', v('a'), [], 6),
      Assign(v('b'), v('a')),
      Machine('add', v('sum'), [v('a'), v('b')]),
      Machine('return', null, [v('sum')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    expect(run(lower(cfg), root.id!), 12);
  });

  test('spilled live values round trip through local slots', () {
    final root = BasicBlock<Operation>([
      for (var i = 0; i < 40; i++) Machine('constant', v('v$i'), [], i),
      Machine('constant', v('sum'), [], 0),
      for (var i = 0; i < 40; i++)
        Machine('add', v('sum'), [v('sum'), v('v$i')]),
      Machine('return', null, [v('sum')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    expect(run(lower(cfg), root.id!), 780);
  });

  test('assembler rejects unknown operation creators', () {
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock<Operation>([
          Machine('constant', v('x'), [], 1),
          Machine('return', null, [v('x')]),
        ]))
        .build();
    final code = lower(cfg);
    expect(code, isNotEmpty);
    cfg.opCreators.clear();
    expect(
        () => cfg.assembleToInstructions(AssemblerConfig<void>(
            contextData: null,
            onSpill: (v, slot, ctx) => Insn('spill', []),
            onReload: (v, slot, ctx) => Insn('reload', []))),
        throwsStateError);
  });
  test('nested branch dead phi never requires an undefined-path register', () {
    for (final condition in [0, 1]) {
      final root = BasicBlock<Operation>([
        Machine('constant', v('a'), [], condition),
        Machine('constant', v('b'), [], 1),
        Machine('branch', ControlFlowGraph.branch, [v('a')]),
      ]);
      final nested = BasicBlock<Operation>([
        Machine('branch', ControlFlowGraph.branch, [v('b')])
      ]);
      final one =
          BasicBlock<Operation>([Machine('constant', v('inner'), [], 1)]);
      final two =
          BasicBlock<Operation>([Machine('constant', v('inner'), [], 2)]);
      final innerJoin =
          BasicBlock<Operation>([Assign(v('result'), v('inner'))]);
      final other =
          BasicBlock<Operation>([Machine('constant', v('result'), [], 3)]);
      final end = BasicBlock<Operation>([
        Machine('return', null, [v('result')])
      ]);
      final cfg =
          ControlFlowGraph.builder().root(root).split(nested, other).build();
      cfg.link(nested, one);
      cfg.link(nested, two);
      cfg.link(one, innerJoin);
      cfg.link(two, innerJoin);
      cfg.link(innerJoin, end);
      cfg.link(other, end);
      expect(run(lower(cfg), root.id!), condition == 1 ? 1 : 3);
    }
  });
}
