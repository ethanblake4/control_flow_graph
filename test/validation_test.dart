import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

final class Value extends Operation {
  Value(this.result);
  final SSA result;
  @override
  SSA get writesTo => result;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      Value(writesTo ?? result);
}

final class Use extends Operation {
  Use(this.input);
  final SSA input;
  @override
  Set<SSA> get readsFrom => {input};
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      Use(readsFrom?.single ?? input);
}

final class Branch extends Operation {
  Branch(this.target);
  final int target;
  @override
  bool get isTerminator => true;
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) => this;
}

ControlFlowGraph diamond() {
  final root = BasicBlock<Operation>([Value(SSA('x'))], label: 'root');
  final left = BasicBlock<Operation>([Value(SSA('x'))], label: 'left');
  final right = BasicBlock<Operation>([Value(SSA('x'))], label: 'right');
  final join = BasicBlock<Operation>([Use(SSA('x'))], label: 'join');
  final graph = ControlFlowGraph()..append(root);
  graph.root = root;
  graph.link(root, left);
  graph.link(root, right);
  graph.link(left, join);
  graph.link(right, join);
  graph.insertPhiNodes();
  graph.computeSemiPrunedSSA();
  return graph;
}

void main() {
  test('SSA validator accepts a phi with values on their own edges', () {
    final graph = diamond();
    expect(() => validateSSA(graph), returnsNormally);
    expect(dominates(graph, graph.root.id!, graph['join']!.id!), isTrue);
    expect(dominates(graph, graph['left']!.id!, graph['right']!.id!), isFalse);
  });

  test('SSA validator rejects a missing phi predecessor', () {
    final graph = diamond();
    final phi = graph['join']!.code.whereType<PhiNode>().single;
    phi.incoming.remove(graph['left']!.id!);
    expect(() => validateSSA(graph), throwsStateError);
  });

  test('SSA validator rejects a value from the wrong phi edge', () {
    final graph = diamond();
    final phi = graph['join']!.code.whereType<PhiNode>().single;
    phi.incoming[graph['left']!.id!] = phi.incoming[graph['right']!.id!]!;
    phi.sources
      ..clear()
      ..addAll(phi.incoming.values);
    expect(() => validateSSA(graph), throwsStateError);
  });

  test('SSA validator rejects disagreement between phi sources and edges', () {
    final graph = diamond();
    final phi = graph['join']!.code.whereType<PhiNode>().single;
    phi.sources.clear();
    expect(() => validateSSA(graph), throwsStateError);
  });

  test('SSA validator accepts one value on multiple phi edges', () {
    final graph = diamond();
    final phi = graph['join']!.code.whereType<PhiNode>().single;
    final rootValue = graph.root.code.whereType<Value>().single.result;
    phi.incoming
      ..[graph['left']!.id!] = rootValue
      ..[graph['right']!.id!] = rootValue;
    phi.sources
      ..clear()
      ..add(rootValue);
    expect(() => validateSSA(graph), returnsNormally);
  });

  test('SSA validator accepts immediate operands without definitions', () {
    final graph = ControlFlowGraph.builder()
        .root(BasicBlock<Operation>([
          Use(ImmediateSSA('@one', 1)),
          Use(SSA('@1')),
        ]))
        .build();
    expect(() => validateControlFlowGraph(graph), returnsNormally);
    graph.insertPhiNodes();
    graph.computeSemiPrunedSSA();
    expect(() => validateSSA(graph), returnsNormally);
  });

  test('SSA validator rejects a real input without a definition', () {
    final graph = ControlFlowGraph.builder()
        .root(BasicBlock<Operation>([Use(SSA('missing'))]))
        .build();
    graph.insertPhiNodes();
    graph.computeSemiPrunedSSA();
    expect(() => validateSSA(graph), throwsStateError);
  });

  test('CFG validator accepts block IDs and unclassified terminators', () {
    final root = BasicBlock<Operation>([], label: 'root');
    final target = BasicBlock<Operation>([], label: 'target');
    final graph = ControlFlowGraph()..append(root);
    graph.root = root;
    graph.link(root, target);
    root.code.add(Branch(target.id!));
    expect(
      () => validateControlFlowGraph(
        graph,
        branchTarget: (op) => op is Branch ? op.target : null,
        isUnconditionalBranch: (op) => op is Branch,
      ),
      returnsNormally,
    );
    expect(() => validateControlFlowGraph(graph), returnsNormally);
  });

  test('CFG validator rejects a branch without its graph edge', () {
    final root = BasicBlock<Operation>([], label: 'root');
    final target = BasicBlock<Operation>([], label: 'target');
    final graph = ControlFlowGraph()
      ..append(root)
      ..append(target);
    graph.root = root;
    root.code.add(Branch(target.id!));
    expect(
      () => validateControlFlowGraph(
        graph,
        branchTarget: (op) => op is Branch ? op.target : null,
      ),
      throwsStateError,
    );
  });
}
