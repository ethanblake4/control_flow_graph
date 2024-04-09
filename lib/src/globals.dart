import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';

Map<String, Set<int>> calculateGlobals(
    CFG graph, Map<int, BasicBlock> ids, int root) {
  final symbols = <String, Set<int>>{};
  final globals = <String>{};
  final queue = ListQueue.of([root]);
  final visited = <int>{};

  while (queue.isNotEmpty) {
    final node = queue.removeFirst();
    if (!visited.add(node)) {
      continue;
    }

    final locals = <String>{};

    for (final op in ids[node]!.code) {
      for (final ssa in op.readsFrom) {
        if (!locals.contains(ssa.name)) {
          globals.add(ssa.name);
        }
      }
      final writesTo = op.writesTo;
      if (writesTo != null) {
        locals.add(writesTo.name);
        if (symbols.containsKey(writesTo.name)) {
          symbols[writesTo.name]!.add(node);
        } else {
          symbols[writesTo.name] = {node};
        }
      }
    }

    queue.addAll(graph.successorsOf(node));
  }

  final keys = symbols.keys.toList();
  for (final s in keys) {
    if (!globals.contains(s)) {
      symbols.remove(s);
    }
  }

  return symbols;
}
