import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

class Effect extends Operation {
  final SSA? target;
  final Set<SSA> inputs;
  Effect([this.target, this.inputs = const {}]);

  @override
  SSA? get writesTo => target;
  @override
  Set<SSA> get readsFrom => inputs;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      Effect(writesTo ?? target, readsFrom ?? inputs);
}

class PureValue extends Effect {
  PureValue(super.target, [super.inputs]);
  @override
  bool get isPure => true;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      PureValue(writesTo ?? target!, readsFrom ?? inputs);
}

ControlFlowGraph toSSA(BasicBlock block) {
  final cfg = ControlFlowGraph.builder().root(block).build();
  cfg.insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  return cfg;
}

void main() {
  test('unused effectful and potentially throwing definitions survive', () {
    final block =
        BasicBlock<Operation>([Effect(SSA('call')), Effect(SSA('throwing'))]);
    final cfg = toSSA(block);
    cfg.removeUnusedDefines();
    expect(block.code, hasLength(2));
    expect(cfg.defines, hasLength(2));
  });

  test('dead pure chains are removed and def-use metadata stays consistent',
      () {
    final a = SSA('a'), b = SSA('b'), c = SSA('c');
    final block = BasicBlock<Operation>([
      PureValue(a),
      Assign(b, a),
      PureValue(c, {b})
    ]);
    final cfg = toSSA(block);
    cfg.removeUnusedDefines();
    expect(block.code, isEmpty);
    expect(cfg.defines, isEmpty);
    expect(cfg.blockDefines!.values.every((values) => values.isEmpty), isTrue);
    expect(cfg.uses!.values.every((uses) => uses.isEmpty), isTrue);
    expect(cfg.ssaGraph.vertices, isEmpty);
    cfg.removeUnusedDefines();
    expect(block.code, isEmpty);
  });

  test('effectful operation retains the pure values it consumes', () {
    final value = SSA('value');
    final block = BasicBlock<Operation>([
      PureValue(value),
      Effect(null, {value})
    ]);
    final cfg = toSSA(block);
    cfg.removeUnusedDefines();
    expect(block.code, hasLength(2));
    expect(cfg.defines, hasLength(1));
  });

  test('dead-result cleanup reindexes operations replaced after SSA', () {
    final oldValue = SSA('old');
    final replacement = SSA('replacement');
    final block = BasicBlock<Operation>([PureValue(oldValue)]);
    final cfg = toSSA(block);
    block.code[0] = PureValue(replacement);

    cfg.removeUnusedDefines(canRemove: (op) => op is PureValue);

    expect(block.code, isEmpty);
    expect(cfg.defines, isEmpty);
    expect(cfg.uses, isEmpty);
    expect(cfg.ssaGraph.vertices, isEmpty);
  });

  test('control-flow sentinel cannot be removed by a pure annotation', () {
    final block = BasicBlock<Operation>([PureValue(ControlFlowGraph.branch)]);
    final cfg = toSSA(block);
    cfg.removeUnusedDefines();
    expect(block.code, hasLength(1));
  });

  test('block trimming preserves effectful and empty terminal blocks', () {
    final root = BasicBlock<Operation>([Effect()]);
    final terminal = BasicBlock<Operation>([Effect(SSA('result'))]);
    final cfg = ControlFlowGraph.builder().root(root).then(terminal).build();
    cfg.insertPhiNodes();
    cfg.computeSemiPrunedSSA();
    cfg.removeEmptyAndUnusedBlocks();
    expect(cfg.graph.vertices, contains(terminal.id));
    expect(terminal.code, hasLength(1));
    terminal.code.clear();
    cfg.removeEmptyAndUnusedBlocks();
    expect(cfg.graph.vertices, contains(terminal.id));
  });

  test('block trimming bypasses an empty intermediary', () {
    final root = BasicBlock<Operation>([Effect()]);
    final intermediary = BasicBlock<Operation>([]);
    final terminal = BasicBlock<Operation>([Effect()]);
    final cfg = ControlFlowGraph.builder()
        .root(root)
        .then(intermediary)
        .then(terminal)
        .build();
    cfg.insertPhiNodes();
    cfg.computeSemiPrunedSSA();
    cfg.removeEmptyAndUnusedBlocks();
    expect(cfg.graph.vertices, isNot(contains(intermediary.id)));
    expect(cfg.graph.successorsOf(root.id!), contains(terminal.id));
  });
  test('block trimming preserves conditional successor ordering', () {
    final root = BasicBlock<Operation>([Effect(ControlFlowGraph.branch)]);
    final first = BasicBlock<Operation>([]);
    final second = BasicBlock<Operation>([Effect()]);
    final end = BasicBlock<Operation>([Effect()]);
    final cfg = ControlFlowGraph.builder()
        .root(root)
        .split(first, second)
        .merge(end)
        .build();
    cfg.insertPhiNodes();
    cfg.computeSemiPrunedSSA();
    final original = cfg.graph.successorsOf(root.id!).toList();
    cfg.removeEmptyAndUnusedBlocks();
    expect(cfg.graph.successorsOf(root.id!).toList(), original);
  });
}
