import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

final class Value extends Operation {
  final SSA result;
  Value(this.result);
  @override
  SSA get writesTo => result;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      Value(writesTo ?? result);
}

final class Use extends Operation {
  final SSA input;
  Use(this.input);
  @override
  Set<SSA> get readsFrom => {input};
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      Use(readsFrom?.single ?? input);
}

void main() {
  test('shared operands cannot mutate earlier SSA definitions', () {
    final shared = SSA('argument');
    final cfg = ControlFlowGraph.builder()
        .root(BasicBlock<Operation>([
          Value(shared),
          Assign(shared, shared),
          Use(shared),
        ]))
        .build();
    cfg.insertPhiNodes();
    cfg.computeSemiPrunedSSA();
    expect(cfg.root.code[0].writesTo!.version, 0);
    expect(cfg.root.code[1].writesTo!.version, 1);
    expect(cfg.root.code[1].readsFrom.single.version, 0);
    expect(cfg.root.code[2].readsFrom.single.version, 1);
    expect(cfg.defines, hasLength(2));
    final definition = cfg.defines![cfg.root.code[1].writesTo]!;
    expect(cfg.ssaGraph.successorsOf(definition), hasLength(1));
    expect(shared.version, -1);
  });
}
