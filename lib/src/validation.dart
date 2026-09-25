import 'package:control_flow_graph/src/cfg.dart';
import 'package:control_flow_graph/src/operation.dart';
import 'package:control_flow_graph/src/ssa.dart';

bool _isImmediate(SSA value) =>
    value is ImmediateSSA ||
    (value.name.startsWith('@') && value.name != '@branch');

/// Whether [definition] dominates [use] in [graph].
bool dominates(ControlFlowGraph graph, int definition, int use) {
  var current = use;
  while (current != definition) {
    final parent = graph.dominators[current];
    if (parent == null || parent == current) return false;
    current = parent;
  }
  return true;
}

/// Checks unique definitions and dominance in an SSA graph.
///
/// Phi inputs are read on their matching predecessor edges. The graph's
/// branch marker is a control-flow output rather than a value definition.
void validateSSA(ControlFlowGraph graph) {
  if (!graph.inSSAForm) {
    throw StateError('SSA validation requires an SSA graph');
  }
  final reachable = <int>{};
  final pending = <int>[graph.root.id!];
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (reachable.add(id)) pending.addAll(graph.graph.successorsOf(id));
  }

  final definitions = <SSA, (int, int)>{};
  for (final id in reachable) {
    final block = graph[id]!;
    for (var index = 0; index < block.code.length; index++) {
      final target = block.code[index].writesTo;
      if (target == null || target.name.startsWith('@')) continue;
      if (target.version < 0) {
        throw StateError('B$id: unversioned definition $target');
      }
      if (definitions.containsKey(target)) {
        throw StateError('B$id: $target has multiple definitions');
      }
      definitions[target] = (id, index);
    }
  }

  for (final id in reachable) {
    final block = graph[id]!;
    for (var index = 0; index < block.code.length; index++) {
      final operation = block.code[index];
      if (operation is PhiNode) {
        final predecessors = graph.graph.predecessorsOf(id).toSet();
        if (operation.incoming.keys
                .toSet()
                .difference(predecessors)
                .isNotEmpty ||
            predecessors
                .difference(operation.incoming.keys.toSet())
                .isNotEmpty) {
          throw StateError('B$id: phi inputs do not cover predecessors');
        }
        if (operation.incoming.values.toSet().length !=
                operation.sources.length ||
            !operation.incoming.values.toSet().containsAll(operation.sources)) {
          throw StateError('B$id: phi sources disagree with incoming edges');
        }
        for (final entry in operation.incoming.entries) {
          final source = entry.value;
          if (_isImmediate(source)) continue;
          final definition = definitions[source];
          if (definition == null) {
            throw StateError('B$id: $operation reads undefined $source');
          }
          if (!dominates(graph, definition.$1, entry.key)) {
            throw StateError(
              'B$id: phi input $source does not dominate predecessor B${entry.key}',
            );
          }
        }
        continue;
      }
      for (final source in operation.readsFrom) {
        if (_isImmediate(source)) continue;
        final definition = definitions[source];
        if (definition == null) {
          throw StateError('B$id: $operation reads undefined $source');
        }
        final (definitionBlock, definitionIndex) = definition;
        if (!dominates(graph, definitionBlock, id) ||
            (definitionBlock == id && definitionIndex >= index)) {
          throw StateError('B$id: $source does not dominate $operation');
        }
      }
    }
  }
}

/// Checks definitions, terminator placement, and normal control-flow edges.
///
/// [branchTarget] identifies a block ID or label named by a branch. [isExit] identifies
/// operations that leave the graph. [isUnconditionalBranch] marks branches
/// that cannot also fall through. Frontends with synthetic edges, such as
/// exception handlers, can list their target block IDs in [ignoredSuccessors].
void validateControlFlowGraph(
  ControlFlowGraph graph, {
  Object? Function(Operation)? branchTarget,
  bool Function(Operation)? isExit,
  bool Function(Operation)? isUnconditionalBranch,
  Set<int> ignoredSuccessors = const {},
}) {
  final blocks = [
    for (final id in graph.graph.vertices) graph[id]!,
  ];
  final definitions = <String>{};
  for (final block in blocks) {
    for (final op in block.code) {
      if (op.writesTo case final result?) definitions.add(result.name);
    }
  }
  for (final block in blocks) {
    for (var index = 0; index < block.code.length; index++) {
      final op = block.code[index];
      for (final input in op.readsFrom) {
        if (_isImmediate(input)) continue;
        if (!definitions.contains(input.name)) {
          throw StateError(
            '${block.label ?? block.id}: $op reads undefined $input',
          );
        }
      }
      final target = branchTarget?.call(op);
      final exits = isExit?.call(op) ?? false;
      if (target == null && !exits && !op.isTerminator) continue;
      if (index != block.code.length - 1) {
        throw StateError(
          '${block.label ?? block.id}: operation follows terminator $op',
        );
      }
      final successors = graph.graph.successorsOf(block.id!).toSet();
      if (target != null) {
        final destination = graph[target];
        if (destination == null || !successors.contains(destination.id)) {
          throw StateError(
            '${block.label ?? block.id}: missing edge to $target',
          );
        }
        if ((isUnconditionalBranch?.call(op) ?? false) &&
            successors.difference(
                {...ignoredSuccessors, destination.id!}).isNotEmpty) {
          throw StateError(
            '${block.label ?? block.id}: unconditional jump has fallthrough',
          );
        }
      } else if (exits && successors.difference(ignoredSuccessors).isNotEmpty) {
        throw StateError(
          '${block.label ?? block.id}: exit has fallthrough',
        );
      }
    }
  }
}
