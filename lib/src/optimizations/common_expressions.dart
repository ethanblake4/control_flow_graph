import '../cfg.dart';
import '../operation.dart';
import '../ssa.dart';

/// Reuses deterministic expressions whose definitions dominate the duplicate.
///
/// [keyOf] must include every operand and option affecting the result, or return
/// null for operations that cannot be reused. Its second argument resolves SSA
/// copies for use in keys without changing the operation's operand positions.
/// Unlike dead-code removal, a
/// potentially throwing operation is eligible when an identical operation has
/// already succeeded. Mutable reads and identity-bearing allocations are not.
/// The graph must describe normal control flow: exceptional edges out of the
/// middle of a block do not establish instruction-level dominance.
void eliminateCommonExpressions(
  ControlFlowGraph graph,
  Object? Function(Operation, SSA Function(SSA)) keyOf,
) {
  if (!graph.inSSAForm) {
    throw StateError('Common-expression elimination requires SSA form');
  }
  final available = <Object, SSA>{};
  final copies = <SSA, SSA>{
    for (final id in graph.graph.vertices)
      for (final op in graph[id]!.code.whereType<Assign>()) op.target: op.source,
  };
  final tree = graph.dominatorTree;

  SSA resolve(SSA value) {
    while (copies.containsKey(value)) {
      value = copies[value]!;
    }
    return value;
  }

  void visit(int id) {
    final added = <Object>[];
    final code = graph[id]!.code;
    for (var i = 0; i < code.length; i++) {
      final op = code[i];
      final target = op.writesTo;
      if (target == null) continue;
      final key = keyOf(op, resolve);
      if (key == null) continue;
      final previous = available[key];
      if (previous != null) {
        code[i] = Assign(target, previous);
        copies[target] = previous;
      } else {
        available[key] = target;
        added.add(key);
      }
    }
    for (final child in tree.successorsOf(id)) {
      if (child != id) visit(child);
    }
    for (final key in added) {
      available.remove(key);
    }
  }

  visit(graph.root.id!);
  graph.refreshSSA();
}
