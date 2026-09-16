import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/operation.dart' show SpillNode;
import 'package:test/test.dart';

SSA value(String name, [int type = 0]) => SSA(name, type: type);

class Op extends Operation {
  final String kind;
  final SSA? output;
  final List<SSA> args;
  final num immediate;
  Op(this.kind, this.output, [this.args = const [], this.immediate = 0]);
  @override
  SSA? get writesTo => output;
  @override
  Set<SSA> get readsFrom => args.toSet();
  @override
  List<SSA> get operands => args;
  @override
  bool get isTerminator => kind == 'branch' || kind == 'return';
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    final mapping = readsFrom == null
        ? <SSA, SSA>{}
        : Map<SSA, SSA>.fromIterables(this.readsFrom, readsFrom);
    return Op(kind, writesTo ?? output,
        [for (final arg in args) mapping[arg] ?? arg], immediate);
  }

  @override
  Operation copyWithOperands({SSA? writesTo, List<SSA>? operands}) =>
      Op(kind, writesTo ?? output, operands ?? args, immediate);
}

class Insn extends Instruction {
  final String kind;
  final List<num> values;
  Insn(this.kind, this.values);
  @override
  String toString() => "$kind $values";
}

Map<int, List<Instruction>> compile(
  ControlFlowGraph cfg, {
  void Function(ControlFlowGraph cfg)? afterSpilling,
}) {
  final ints = RegisterGroup({0, 1}), doubles = RegisterGroup({8, 9});
  final objects = RegisterGroup({16, 17, 18});
  final overlappingLeft = RegisterGroup({20, 21});
  final overlappingRight = RegisterGroup({20, 21});
  final wide = RegisterGroup({24, 25});
  final narrow = RegisterGroup({24});
  cfg.registerRegType(0, RegType(0, 'integer', {ints}));
  cfg.registerRegType(1, RegType(1, 'double', {doubles}));
  cfg.registerRegType(2, RegType(2, 'object', {objects}));
  cfg.registerRegType(3, RegType(3, 'overlapping-left', {overlappingLeft}));
  cfg.registerRegType(4, RegType(4, 'overlapping-right', {overlappingRight}));
  cfg.registerRegType(5, RegType(5, 'wide', {wide}));
  cfg.registerRegType(6, RegType(6, 'narrow', {narrow}));
  cfg.opCreators[Op] = Creator<Op, void>(
      variants: {},
      selectVariants: (op) {
        final type = op.args.isEmpty ? op.output?.type : op.args.first.type;
        final base = switch (type) {
          1 => 8,
          2 => 16,
          3 || 4 => 20,
          5 || 6 => 24,
          _ => 0,
        };
        return switch (op.kind) {
          'constant' => {
              Variant(result: base),
              if (type != 6) Variant(result: base + 1),
              if (type == 2) Variant(result: base + 2),
            },
          'add' || 'sub' || 'less' => {
              Variant(
                  result: op.output?.type == 1 ? 8 : 0,
                  arguments: [base, base + 1])
            },
          'pack2' => {
              Variant(result: base, arguments: [base, base + 1])
            },
          'observe2' => {
              Variant(result: null, arguments: [base, base + 1])
            },
          'pack3' => {
              Variant(result: base, arguments: [base, base + 1, base + 2])
            },
          'mixed' => {
              Variant(result: 0, arguments: [0, 1, 8, 9])
            },
          'heterogeneous' => {
              Variant(result: 20, arguments: [20, 21])
            },
          'fallback' => {},
          'return' || 'branch' => {
              Variant(result: null, arguments: [base])
            },
          'call' => {Variant(result: 0)},
          'convert' => {
              Variant(result: 8, arguments: [0])
            },
          _ => throw StateError('unknown ${op.kind}'),
        };
      },
      selectClobbers: (op) =>
          op.kind == 'call' ? {0, 1, 8, 9, 16, 17, 18, 20, 21} : {},
      create: (op, context) {
        for (final arg in op.args) {
          expect(
              arg.alloc.register,
              switch (arg.type) {
                0 => isIn([0, 1]),
                1 => isIn([8, 9]),
                2 => isIn([16, 17, 18]),
                3 || 4 => isIn([20, 21]),
                5 => isIn([24, 25]),
                6 => equals(24),
                _ => fail('Unknown register type ${arg.type}'),
              });
        }
        return Insn(op.kind, [
          if (op.output != null && op.output != ControlFlowGraph.branch)
            op.output!.alloc.register,
          for (final arg in op.args) arg.alloc.register,
          if (op.kind == 'constant') op.immediate,
          if (op.kind == 'branch') ...context.successorBlockIds,
        ]);
      });
  cfg.insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  cfg.removeUnusedDefines();
  cfg.spillReloadVariables({
    ints: 2,
    doubles: 2,
    objects: 3,
    overlappingLeft: 2,
    overlappingRight: 2,
    wide: 2,
    narrow: 1,
  });
  afterSpilling?.call(cfg);
  cfg.removePhiNodes(Assign.new);
  cfg.performRegisterAllocation();
  return cfg.assembleToInstructions(AssemblerConfig<void>(
    contextData: null,
    onSpill: (v, slot, ctx) => Insn('spill', [v.register, v.type, slot]),
    onReload: (v, slot, ctx) => Insn('reload', [v.register, v.type, slot]),
    onMove: (a, b, ctx) {
      expect(a.type, b.type);
      return Insn('move', [a.register, b.register]);
    },
    onSwap: (a, b, ctx) {
      expect(a.type, b.type);
      return Insn('swap', [a.register, b.register]);
    },
    onJump: (id, ctx) => Insn('jump', [id]),
  ));
}

num execute(Map<int, List<Instruction>> code, int root,
    {Map<int, num> incoming = const {}}) {
  final regs = <int, num>{...incoming}, slots = <(int, int), num>{};
  final order = code.keys.toList();
  var block = root;
  for (var step = 0; step < 1000; step++) {
    int? next;
    for (final op in code[block]!.cast<Insn>()) {
      final a = op.values;
      int r(int i) => a[i].toInt();
      switch (op.kind) {
        case 'constant':
          regs[r(0)] = a[1];
        case 'add':
          regs[r(0)] = regs[r(1)]! + regs[r(2)]!;
        case 'sub':
          regs[r(0)] = regs[r(1)]! - regs[r(2)]!;
        case 'pack2' || 'heterogeneous' || 'fallback':
          regs[r(0)] = regs[r(1)]! * 10 + regs[r(2)]!;
        case 'pack3':
          regs[r(0)] = regs[r(1)]! * 100 + regs[r(2)]! * 10 + regs[r(3)]!;
        case 'mixed':
          regs[r(0)] = regs[r(1)]! * 1000 +
              regs[r(2)]! * 100 +
              regs[r(3)]! * 10 +
              regs[r(4)]!;
        case 'observe2':
          break;
        case 'less':
          regs[r(0)] = regs[r(1)]! < regs[r(2)]! ? 1 : 0;
        case 'move':
          regs[r(0)] = regs[r(1)]!;
        case 'swap':
          final old = regs[r(0)]!;
          regs[r(0)] = regs[r(1)]!;
          regs[r(1)] = old;
        case 'spill':
          slots[(r(1), r(2))] = regs[r(0)]!;
        case 'reload':
          regs[r(0)] = slots[(r(1), r(2))]!;
        case 'call':
          for (final register in [0, 1, 8, 9, 16, 17, 18, 20, 21]) {
            regs[register] = -999;
          }
          regs[r(0)] = 7;
        case 'convert':
          regs[r(0)] = regs[r(1)]!.toDouble();
        case 'branch':
          next = regs[r(0)] != 0 ? r(1) : r(2);
        case 'jump':
          next = r(0);
        case 'return':
          return regs[r(0)]!;
      }
    }
    block = next ?? order[order.indexOf(block) + 1];
  }
  throw StateError('Loop did not terminate');
}

num run(List<Operation> ops) {
  final root = BasicBlock<Operation>(ops);
  final cfg = ControlFlowGraph.builder().root(root).build();
  return execute(compile(cfg), root.id!);
}

List<Insn> emitted(Map<int, List<Instruction>> program) => [
      for (final block in program.values) ...block.cast<Insn>(),
    ];

void main() {
  test('two-register operand cycle emits one swap', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('left'), 0),
      RegisterInput(value('right'), 1),
      Op('pack2', value('packed'), [value('right'), value('left')]),
      Op('return', null, [value('packed')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final shuffles = emitted(program)
        .where((instruction) =>
            {'swap', 'move', 'spill', 'reload'}.contains(instruction.kind))
        .toList();
    expect(shuffles.map((instruction) => instruction.kind), ['swap']);
    expect(execute(program, root.id!, incoming: {0: 3, 1: 7}), 73);
  });

  test('three-register object cycle uses two swaps', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('first', 2), 16),
      RegisterInput(value('second', 2), 17),
      RegisterInput(value('third', 2), 18),
      Op('pack3', value('packed', 2), [
        value('second', 2),
        value('third', 2),
        value('first', 2),
      ]),
      Op('return', null, [value('packed', 2)]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final shuffles = emitted(program)
        .where((instruction) =>
            {'swap', 'move', 'spill', 'reload'}.contains(instruction.kind))
        .toList();
    expect(shuffles.map((instruction) => instruction.kind), ['swap', 'swap']);
    expect(
      execute(program, root.id!, incoming: {16: 1, 17: 2, 18: 3}),
      231,
    );
  });

  test('duplicate operands use a safe copy rather than a swap', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('source'), 0),
      Op('pack2', value('packed'), [value('source'), value('source')]),
      Op('return', null, [value('packed')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final shuffles = emitted(program)
        .where((instruction) =>
            {'swap', 'move', 'spill', 'reload'}.contains(instruction.kind))
        .toList();
    expect(shuffles.map((instruction) => instruction.kind), ['move']);
    expect(execute(program, root.id!, incoming: {0: 6}), 66);
  });

  test('duplicate resident aliases allow a later operand placement', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('left'), 0),
      RegisterInput(value('right'), 1),
      Op('observe2', null, [value('left'), value('left')]),
      Op('pack2', value('packed'), [value('right'), value('left')]),
      Op('return', null, [value('packed')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final instructions = emitted(program);
    expect(
      instructions.where((instruction) => instruction.kind == 'swap'),
      isEmpty,
    );
    expect(
      instructions.where((instruction) => instruction.kind == 'move'),
      isNotEmpty,
    );
    expect(
      instructions.where((instruction) => instruction.kind == 'reload'),
      isNotEmpty,
    );
    expect(execute(program, root.id!, incoming: {0: 3, 1: 7}), 73);
  });

  test('integer and double cycles swap within their own banks', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('a'), 0),
      RegisterInput(value('b'), 1),
      RegisterInput(value('f', 1), 8),
      RegisterInput(value('g', 1), 9),
      Op('mixed', value('packed'), [
        value('b'),
        value('a'),
        value('g', 1),
        value('f', 1),
      ]),
      Op('return', null, [value('packed')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final swaps = emitted(program)
        .where((instruction) => instruction.kind == 'swap')
        .toList();
    expect(swaps, hasLength(2));
    final swappedPairs = swaps.map((instruction) {
      final registers =
          instruction.values.map((value) => value.toInt()).toList()..sort();
      return registers.join(',');
    }).toSet();
    expect(swappedPairs, {'0,1', '8,9'});
    expect(
      execute(program, root.id!, incoming: {0: 2, 1: 3, 8: 4, 9: 5}),
      3254,
    );
  });

  test('swapped values remain valid across a complete clobber', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('left'), 0),
      RegisterInput(value('right'), 1),
      Op('pack2', value('packed'), [value('right'), value('left')]),
      Op('call', value('called')),
      Op('add', value('result'), [value('packed'), value('called')]),
      Op('return', null, [value('result')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final instructions = emitted(program);
    expect(
      instructions.where((instruction) => instruction.kind == 'swap'),
      hasLength(1),
    );
    expect(
      instructions.where((instruction) => instruction.kind == 'spill'),
      isNotEmpty,
    );
    expect(
      instructions.where((instruction) => instruction.kind == 'reload'),
      isNotEmpty,
    );
    expect(execute(program, root.id!, incoming: {0: 3, 1: 7}), 80);
  });

  test('stored spill remains reloadable after a swap', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('left'), 0),
      RegisterInput(value('right'), 1),
      Op('pack2', value('packed'), [value('right'), value('left')]),
      Op('call', value('called')),
      Op('add', value('sum'), [value('left'), value('called')]),
      Op('add', value('result'), [value('sum'), value('packed')]),
      Op('return', null, [value('result')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg, afterSpilling: (cfg) {
      final code = cfg.root.code;
      final packIndex = code.indexWhere(
        (operation) => operation is Op && operation.kind == 'pack2',
      );
      final pack = code[packIndex] as Op;
      code.insert(packIndex, SpillNode(pack.args[1]));
    });
    final instructions = emitted(program);
    expect(
      instructions.where((instruction) => instruction.kind == 'swap'),
      hasLength(1),
    );
    expect(
      instructions.where((instruction) => instruction.kind == 'reload'),
      isNotEmpty,
    );
    expect(execute(program, root.id!, incoming: {0: 3, 1: 7}), 83);
  });

  test('overlapping register sets without a shared group do not swap', () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('left', 3), 20),
      RegisterInput(value('right', 4), 21),
      Op('heterogeneous', value('packed', 3), [
        value('right', 4),
        value('left', 3),
      ]),
      Op('return', null, [value('packed', 3)]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final instructions = emitted(program);
    expect(
      instructions.where((instruction) => instruction.kind == 'swap'),
      isEmpty,
    );
    expect(
      instructions.where((instruction) =>
          instruction.kind == 'spill' || instruction.kind == 'reload'),
      isNotEmpty,
    );
    expect(execute(program, root.id!, incoming: {20: 4, 21: 9}), 94);
  });

  test('fallback assignment reserves a narrow register before a wide operand',
      () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('wide', 5), 24),
      Op('constant', value('narrow', 6), const [], 9),
      Op('fallback', value('packed', 5), [
        value('wide', 5),
        value('narrow', 6),
      ]),
      Op('return', null, [value('packed', 5)]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final program = compile(cfg);
    final instructions = emitted(program);
    final fallback = instructions.singleWhere(
      (instruction) => instruction.kind == 'fallback',
    );
    expect(fallback.values.skip(1), [25, 24]);
    expect(
      instructions.where((instruction) => instruction.kind == 'swap'),
      isEmpty,
    );
    expect(
      instructions.where((instruction) =>
          instruction.kind == 'spill' || instruction.kind == 'reload'),
      isNotEmpty,
    );
    expect(execute(program, root.id!, incoming: {24: 4}), 49);
  });

  test('incoming registers survive reversed operands and destructive reuse',
      () {
    final root = BasicBlock<Operation>([
      RegisterInput(value('a'), 0),
      RegisterInput(value('b'), 1),
      Op('sub', value('difference'), [value('b'), value('a')]),
      Op('add', value('result'), [value('difference'), value('a')]),
      Op('return', null, [value('result')]),
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    expect(execute(compile(cfg), root.id!, incoming: {0: 3, 1: 10}), 10);
  });
  test('duplicate input occupies both constrained integer registers', () {
    expect(
        run([
          Op('constant', value('x'), [], 11),
          Op('add', value('y'), [value('x'), value('x')]),
          Op('return', null, [value('y')])
        ]),
        22);
  });
  test('reverse subtraction preserves operand order', () {
    expect(
        run([
          Op('constant', value('a'), [], 3),
          Op('constant', value('b'), [], 10),
          Op('sub', value('result'), [value('b'), value('a')]),
          Op('return', null, [value('result')])
        ]),
        7);
  });
  test('destructive result preserves a live input with no free register', () {
    expect(
        run([
          Op('constant', value('a'), [], 3),
          Op('constant', value('b'), [], 10),
          Op('add', value('sum'), [value('a'), value('b')]),
          Op('sub', value('result'), [value('sum'), value('a')]),
          Op('return', null, [value('result')])
        ]),
        10);
  });
  test('live integer and double survive complete call clobber', () {
    expect(
        run([
          Op('constant', value('a'), [], 3),
          Op('constant', value('d', 1), [], 2.5),
          Op('call', value('called')),
          Op('add', value('sum'), [value('a'), value('called')]),
          Op('convert', value('converted', 1), [value('sum')]),
          Op('add', value('result', 1), [value('converted', 1), value('d', 1)]),
          Op('return', null, [value('result', 1)])
        ]),
        12.5);
  });
  test('loop phi survives two register bank pressure', () {
    final root = BasicBlock<Operation>([
      Op('constant', value('i'), [], 0),
      Op('constant', value('sum'), [], 0),
      Op('constant', value('limit'), [], 5),
      Op('constant', value('one'), [], 1)
    ]);
    final header = BasicBlock<Operation>([
      Op('less', value('condition'), [value('i'), value('limit')]),
      Op('branch', ControlFlowGraph.branch, [value('condition')])
    ]);
    final body = BasicBlock<Operation>([
      Op('add', value('sum'), [value('sum'), value('i')]),
      Op('add', value('i'), [value('i'), value('one')])
    ]);
    final end = BasicBlock<Operation>([
      Op('return', null, [value('sum')])
    ]);
    final cfg = ControlFlowGraph.builder()
        .root(root)
        .then(header)
        .split(body, end)
        .build();
    cfg.link(body, header);
    expect(execute(compile(cfg), root.id!), 10);
  });
  test('straight line scalar operations need no stores when inputs die', () {
    final root = BasicBlock<Operation>([
      Op('constant', value('a'), [], 3),
      Op('constant', value('b'), [], 10),
      Op('add', value('sum'), [value('a'), value('b')]),
      Op('return', null, [value('sum')])
    ]);
    final cfg = ControlFlowGraph.builder().root(root).build();
    final code = compile(cfg);
    expect(
        code.values
            .expand((ops) => ops)
            .cast<Insn>()
            .where((op) => op.kind == 'spill'),
        isEmpty);
    expect(execute(code, root.id!), 13);
  });
  test('linear block boundaries retain registers without spill or reload', () {
    final root = BasicBlock<Operation>([
      Op('constant', value('a'), [], 3),
      Op('constant', value('b'), [], 10)
    ]);
    final middle = BasicBlock<Operation>([
      Op('add', value('sum'), [value('a'), value('b')])
    ]);
    final end = BasicBlock<Operation>([
      Op('return', null, [value('sum')])
    ]);
    final cfg =
        ControlFlowGraph.builder().root(root).then(middle).then(end).build();
    final code = compile(cfg);
    expect(execute(code, root.id!), 13);
    expect(
        code.values
            .expand((ops) => ops)
            .cast<Insn>()
            .where((op) => op.kind == 'spill' || op.kind == 'reload'),
        isEmpty);
  });
}
