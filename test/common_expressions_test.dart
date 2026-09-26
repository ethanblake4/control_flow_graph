import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

import 'sample_ir.dart';

Object? expressionKey(Operation op, SSA Function(SSA) resolve) {
  if (op is LessThan && op.target.name != ControlFlowGraph.branch.name) {
    return (LessThan, resolve(op.left), resolve(op.right));
  }
  return null;
}

ControlFlowGraph toSSA(ControlFlowGraph graph) {
  graph.insertPhiNodes();
  graph.computeSemiPrunedSSA();
  validateSSA(graph);
  return graph;
}

class MutableRead extends Operation {
  MutableRead(this.target);

  final SSA target;

  @override
  SSA get writesTo => target;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) =>
      MutableRead(writesTo ?? target);
}

void main() {
  test('reuses an expression from a dominating block', () {
    final root = BasicBlock<Operation>([
      LoadImmediate(SSA('x'), 1),
      LoadImmediate(SSA('y'), 2),
      LessThan(SSA('first'), SSA('x'), SSA('y')),
    ]);
    final child = BasicBlock<Operation>([
      LessThan(SSA('second'), SSA('x'), SSA('y')),
      Return(SSA('second')),
    ]);
    final graph =
        toSSA(ControlFlowGraph.builder().root(root).then(child).build());
    final first = root.code.whereType<LessThan>().single.writesTo!;

    eliminateCommonExpressions(graph, expressionKey);

    expect(child.code.whereType<LessThan>(), isEmpty);
    final copy = child.code.whereType<Assign>().single;
    expect(copy.source, first);
    expect(child.code.whereType<Return>().single.value, copy.target);
    validateSSA(graph);
  });

  test('does not reuse an expression from a sibling branch', () {
    final root = BasicBlock<Operation>([
      LoadImmediate(SSA('x'), 1),
      LoadImmediate(SSA('y'), 2),
      LessThan(ControlFlowGraph.branch, SSA('x'), SSA('y')),
    ]);
    final left = BasicBlock<Operation>([
      LessThan(SSA('left'), SSA('x'), SSA('y')),
      Return(SSA('left')),
    ]);
    final right = BasicBlock<Operation>([
      LessThan(SSA('right'), SSA('x'), SSA('y')),
      Return(SSA('right')),
    ]);
    final graph =
        toSSA(ControlFlowGraph.builder().root(root).split(left, right).build());

    eliminateCommonExpressions(graph, expressionKey);

    expect(left.code.whereType<LessThan>(), hasLength(1));
    expect(right.code.whereType<LessThan>(), hasLength(1));
    validateSSA(graph);
  });

  test('keeps an expression with a loop phi input distinct', () {
    final root = BasicBlock<Operation>([
      LoadImmediate(SSA('value'), 1),
      LoadImmediate(SSA('limit'), 5),
      LessThan(SSA('beforeLoop'), SSA('value'), SSA('limit')),
    ]);
    final header = BasicBlock<Operation>([
      LessThan(SSA('inLoop'), SSA('value'), SSA('limit')),
      LessThan(ControlFlowGraph.branch, SSA('value'), SSA('limit')),
    ]);
    final body = BasicBlock<Operation>([
      LoadImmediate(SSA('value'), 2),
    ]);
    final exit = BasicBlock<Operation>([Return(SSA('inLoop'))]);
    final graph = ControlFlowGraph();
    graph.append(root);
    graph.root = root;
    graph.link(root, header);
    graph.link(header, body);
    graph.link(header, exit);
    graph.link(body, header);
    toSSA(graph);
    final phi = header.code.whereType<PhiNode>().single;

    eliminateCommonExpressions(graph, expressionKey);

    expect(header.code.whereType<LessThan>().first.left, phi.target);
    expect(root.code.whereType<LessThan>().single.left, isNot(phi.target));
    validateSSA(graph);
  });

  test('preserves repeated operands when resolving copy keys', () {
    final block = BasicBlock<Operation>([
      LoadImmediate(SSA('value'), 1),
      Assign(SSA('alias'), SSA('value')),
      LessThan(SSA('first'), SSA('alias'), SSA('alias')),
      LessThan(SSA('second'), SSA('alias'), SSA('alias')),
      Return(SSA('second')),
    ]);
    final graph = toSSA(ControlFlowGraph.builder().root(block).build());
    final alias = block.code.whereType<Assign>().single.target;

    eliminateCommonExpressions(graph, expressionKey);

    final comparison = block.code.whereType<LessThan>().single;
    expect(comparison.left, comparison.right);
    expect(comparison.left, alias);
    final copy = block.code.whereType<Assign>().last;
    expect(copy.source, comparison.target);
    expect(block.code.whereType<Return>().single.value, copy.target);
    validateSSA(graph);
  });

  test('resolves distinct copy operands without rewriting the source operation',
      () {
    final block = BasicBlock<Operation>([
      LoadImmediate(SSA('value'), 1),
      Assign(SSA('leftAlias'), SSA('value')),
      Assign(SSA('rightAlias'), SSA('value')),
      LessThan(SSA('first'), SSA('leftAlias'), SSA('rightAlias')),
      LessThan(SSA('second'), SSA('value'), SSA('value')),
      Return(SSA('second')),
    ]);
    final graph = toSSA(ControlFlowGraph.builder().root(block).build());
    final leftAlias = block.code.whereType<Assign>().first.target;
    final rightAlias = block.code.whereType<Assign>().last.target;

    eliminateCommonExpressions(graph, expressionKey);

    final comparison = block.code.whereType<LessThan>().single;
    expect(comparison.left, leftAlias);
    expect(comparison.right, rightAlias);
    final copy = block.code.whereType<Assign>().last;
    expect(copy.source, comparison.target);
    expect(block.code.whereType<Return>().single.value, copy.target);
    validateSSA(graph);
  });

  test('leaves mutable reads and operations without a key alone', () {
    final block = BasicBlock<Operation>([
      MutableRead(SSA('firstRead')),
      MutableRead(SSA('secondRead')),
      LoadImmediate(SSA('firstConstant'), 1),
      LoadImmediate(SSA('secondConstant'), 1),
    ]);
    final graph = toSSA(ControlFlowGraph.builder().root(block).build());

    eliminateCommonExpressions(graph, expressionKey);

    expect(block.code.whereType<MutableRead>(), hasLength(2));
    expect(block.code.whereType<LoadImmediate>(), hasLength(2));
    validateSSA(graph);
  });
}
