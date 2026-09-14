import 'package:control_flow_graph/control_flow_graph.dart';
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

Map<int, List<Instruction>> compile(ControlFlowGraph cfg) {
  final ints = RegisterGroup({0, 1}), doubles = RegisterGroup({8, 9});
  cfg.registerRegType(0, RegType(0, 'integer', {ints}));
  cfg.registerRegType(1, RegType(1, 'double', {doubles}));
  cfg.opCreators[Op] = Creator<Op, void>(
      variants: {},
      selectVariants: (op) {
        final base =
            (op.args.isEmpty ? op.output?.type : op.args.first.type) == 1
                ? 8
                : 0;
        return switch (op.kind) {
          'constant' => {Variant(result: base), Variant(result: base + 1)},
          'add' || 'sub' || 'less' => {
              Variant(
                  result: op.output?.type == 1 ? 8 : 0,
                  arguments: [base, base + 1])
            },
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
      selectClobbers: (op) => op.kind == 'call' ? {0, 1, 8, 9} : {},
      create: (op, context) {
        for (final arg in op.args) {
          expect(
              arg.alloc.register, arg.type == 0 ? isIn([0, 1]) : isIn([8, 9]));
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
  cfg.spillReloadVariables({ints: 2, doubles: 2});
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

num execute(Map<int, List<Instruction>> code, int root) {
  final regs = <int, num>{}, slots = <(int, int), num>{};
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
          for (final register in [0, 1, 8, 9]) {
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

void main() {
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
