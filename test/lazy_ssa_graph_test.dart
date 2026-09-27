import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

final class _Value extends Operation {
  _Value(this.result, [this.inputs = const {}]);

  final SSA result;
  final Set<SSA> inputs;

  @override
  SSA get writesTo => result;

  @override
  Set<SSA> get readsFrom => inputs;

  @override
  bool get isPure => true;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      _Value(writesTo ?? result, readsFrom ?? inputs);
}

final class _Use extends Operation {
  _Use(this.inputs);

  final Set<SSA> inputs;

  @override
  Set<SSA> get readsFrom => inputs;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      _Use(readsFrom ?? inputs);
}

ControlFlowGraph _toSSA(List<Operation> code) {
  final cfg =
      ControlFlowGraph.builder().root(BasicBlock<Operation>(code)).build();
  cfg.insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  return cfg;
}

void main() {
  test('SSA graph connects each definition to its uses', () {
    final a = SSA('a');
    final b = SSA('b');
    final cfg = _toSSA([
      _Value(a),
      _Value(b, {a}),
      _Use({a, b}),
    ]);
    final first = cfg.root.code[0];
    final second = cfg.root.code[1];
    final sink = cfg.root.code[2];
    final firstDefinition = cfg.defines![first.writesTo]!;
    final secondDefinition = cfg.defines![second.writesTo]!;

    expect(
      cfg.ssaGraph.successorsOf(firstDefinition).map((use) => use.op),
      containsAll([second, sink]),
    );
    expect(
      cfg.ssaGraph.successorsOf(secondDefinition).map((use) => use.op),
      contains(sink),
    );
  });

  test('refreshSSA replaces edges after operation rewrites', () {
    final a = SSA('a');
    final b = SSA('b');
    final cfg = _toSSA([
      _Value(a),
      _Value(b, {a}),
      _Use({b})
    ]);
    final oldValue = cfg.root.code[1].writesTo!;
    final oldDefinition = cfg.defines![oldValue]!;
    expect(cfg.ssaGraph.successorsOf(oldDefinition), hasLength(1));

    final newValue = SSA('c', version: oldValue.version);
    cfg.root.code[1] = _Value(newValue, {cfg.root.code[0].writesTo!});
    cfg.root.code[2] = _Use({newValue});
    cfg.refreshSSA();

    final newDefinition = cfg.defines![newValue]!;
    expect(cfg.defines, isNot(contains(oldValue)));
    expect(cfg.uses![oldValue], isNull);
    expect(cfg.ssaGraph.vertices, isNot(contains(oldDefinition)));
    expect(cfg.ssaGraph.successorsOf(newDefinition).single.op,
        same(cfg.root.code[2]));
  });

  test('clone without refresh rebuilds edges from its own operations', () {
    final value = SSA('value');
    final original = _toSSA([
      _Value(value),
      _Use({value})
    ]);
    original.ssaGraph;
    final copy = original.clone(refresh: false);
    copy.refreshSSA();

    final copyValue = copy.root.code[0].writesTo!;
    final copyDefinition = copy.defines![copyValue]!;
    expect(copy.ssaGraph.successorsOf(copyDefinition).single.op,
        same(copy.root.code[1]));
    expect(copyDefinition.op, isNot(same(original.root.code[0])));
  });

  for (final accessedBeforeCleanup in [false, true]) {
    test('DCE updates SSA graph after prior access: $accessedBeforeCleanup',
        () {
      final live = SSA('live');
      final dead = SSA('dead');
      final cfg = _toSSA([
        _Value(live),
        _Value(dead, {live}),
        _Use({live}),
      ]);
      if (accessedBeforeCleanup) {
        expect(cfg.ssaGraph.vertices, hasLength(3));
      }

      cfg.removeUnusedDefines();

      expect(cfg.root.code, hasLength(2));
      expect(cfg.defines, hasLength(1));
      final liveDefinition = cfg.defines![cfg.root.code.first.writesTo]!;
      expect(cfg.ssaGraph.successorsOf(liveDefinition).single.op,
          same(cfg.root.code.last));
      expect(cfg.ssaGraph.vertices, hasLength(2));
    });
  }
}
