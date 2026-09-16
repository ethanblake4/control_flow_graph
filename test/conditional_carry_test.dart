import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';
import 'constrained_allocation_test.dart' as fixture;

class Conditional extends fixture.Op {
  Conditional(SSA condition)
      : super('branch', ControlFlowGraph.branch, [condition]);
  @override
  bool get isConditionalBranch => true;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      Conditional(readsFrom?.single ?? args.single);
  @override
  Operation copyWithOperands({SSA? writesTo, List<SSA>? operands}) =>
      Conditional(operands?.single ?? args.single);
}

Map<int, List<Instruction>> compile(ControlFlowGraph cfg) {
  final ints = RegisterGroup({0, 1}), doubles = RegisterGroup({8, 9});
  cfg.registerRegType(0, RegType(0, 'integer', {ints}));
  cfg.registerRegType(1, RegType(1, 'double', {doubles}));
  final creator = Creator<fixture.Op, void>(
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
          _ => throw StateError(op.kind),
        };
      },
      selectClobbers: (op) => op.kind == 'call' ? {0, 1, 8, 9} : {},
      create: (op, ctx) => fixture.Insn(op.kind, [
            if (op.output != null && op.output != ControlFlowGraph.branch)
              op.output!.alloc.register,
            for (final arg in op.args) arg.alloc.register,
            if (op.kind == 'constant') op.immediate,
            if (op.kind == 'branch') ...ctx.successorBlockIds,
          ]));
  cfg.opCreators[fixture.Op] = creator;
  cfg.opCreators[Conditional] = creator;
  cfg.insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  cfg.removeUnusedDefines();
  cfg.spillReloadVariables({ints: 2, doubles: 2});
  cfg.removePhiNodes(Assign.new);
  cfg.performRegisterAllocation();
  return cfg.assembleToInstructions(AssemblerConfig<void>(
      contextData: null,
      onSpill: (v, s, c) => fixture.Insn('spill', [v.register, v.type, s]),
      onReload: (v, s, c) => fixture.Insn('reload', [v.register, v.type, s]),
      onMove: (a, b, c) => fixture.Insn('move', [a.register, b.register]),
      onSwap: (a, b, c) => fixture.Insn('swap', [a.register, b.register]),
      onJump: (id, c) => fixture.Insn('jump', [id])));
}

SSA v(String name, [int type = 0]) => fixture.value(name, type);
fixture.Op op(String kind, SSA? result,
        [List<SSA> args = const [], num immediate = 0]) =>
    fixture.Op(kind, result, args, immediate);
Iterable<fixture.Insn> traffic(Map<int, List<Instruction>> code) => code.values
    .expand((b) => b)
    .cast<fixture.Insn>()
    .where((i) => i.kind == 'spill' || i.kind == 'reload');
void main() {
  test('both single-predecessor alternatives inherit mixed-bank registers', () {
    final root = BasicBlock<Operation>([
      RegisterInput(v('condition'), 0),
      RegisterInput(v('number', 1), 8),
      Conditional(v('condition'))
    ]);
    final yes = BasicBlock<Operation>([
      op('return', null, [v('number', 1)])
    ]);
    final no = BasicBlock<Operation>([
      op('return', null, [v('number', 1)])
    ]);
    final cfg = ControlFlowGraph.builder().root(root).split(yes, no).build();
    final code = compile(cfg);
    expect(traffic(code), isEmpty);
    for (final condition in [0, 1]) {
      expect(fixture.execute(code, root.id!, incoming: {0: condition, 8: 2.5}),
          2.5);
    }
  });
  test('sibling clobbers do not mutate the other successor register snapshot',
      () {
    final root = BasicBlock<Operation>([
      RegisterInput(v('condition'), 0),
      RegisterInput(v('number', 1), 8),
      Conditional(v('condition'))
    ]);
    final yes = BasicBlock<Operation>([
      op('call', v('called')),
      op('convert', v('converted', 1), [v('called')]),
      op('add', v('sum', 1), [v('converted', 1), v('number', 1)]),
      op('return', null, [v('sum', 1)])
    ]);
    final no = BasicBlock<Operation>([
      op('return', null, [v('number', 1)])
    ]);
    final cfg = ControlFlowGraph.builder().root(root).split(yes, no).build();
    final code = compile(cfg);
    expect(fixture.execute(code, root.id!, incoming: {0: 1, 8: 2.5}), 9.5);
    expect(fixture.execute(code, root.id!, incoming: {0: 0, 8: 2.5}), 2.5);
    expect(code[no.id!]!.cast<fixture.Insn>().where((i) => i.kind == 'reload'),
        isEmpty);
  });
  test('unmarked synthetic successors continue using canonical spills', () {
    final root = BasicBlock<Operation>([
      RegisterInput(v('condition'), 0),
      RegisterInput(v('number', 1), 8),
      op('branch', ControlFlowGraph.branch, [v('condition')])
    ]);
    final yes = BasicBlock<Operation>([
      op('return', null, [v('number', 1)])
    ]);
    final no = BasicBlock<Operation>([
      op('return', null, [v('number', 1)])
    ]);
    final cfg = ControlFlowGraph.builder().root(root).split(yes, no).build();
    final code = compile(cfg);
    expect(traffic(code).where((i) => i.kind == 'spill').length, 1);
    expect(traffic(code).where((i) => i.kind == 'reload').length, 2);
  });
  test('loop phis keep canonical backedge values with conditional body carry',
      () {
    final root = BasicBlock<Operation>([
      op('constant', v('i'), [], 0),
      op('constant', v('sum'), [], 0),
      op('constant', v('limit'), [], 7),
      op('constant', v('one'), [], 1)
    ]);
    final header = BasicBlock<Operation>([
      op('less', v('condition'), [v('i'), v('limit')]),
      Conditional(v('condition'))
    ]);
    final body = BasicBlock<Operation>([
      op('add', v('sum'), [v('sum'), v('i')]),
      op('add', v('i'), [v('i'), v('one')])
    ]);
    final end = BasicBlock<Operation>([
      op('return', null, [v('sum')])
    ]);
    final cfg = ControlFlowGraph.builder()
        .root(root)
        .then(header)
        .split(body, end)
        .build();
    cfg.link(body, header);
    expect(fixture.execute(compile(cfg), root.id!), 21);
  });
}
