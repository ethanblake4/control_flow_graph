import 'dart:collection';

import 'package:control_flow_graph/src/cfg.dart';

Map<String, Set<int>> calculateGlobals(ControlFlowGraph cfg) {
  final graph = cfg.graph, root = cfg.root;
  final symbols = <String, Set<int>>{};
  final globals = <String>{};
  final queue = ListQueue.of([root.id!]);
  final visited = <int>{};

  while (queue.isNotEmpty) {
    final node = queue.removeFirst();
    if (!visited.add(node)) {
      continue;
    }

    final locals = <String>{};

    for (final op in cfg[node]!.code) {
      for (final ssa in op.readsFrom) {
        if (!locals.contains(ssa.name)) {
          globals.add(ssa.name);
        }
      }
      for (final ssa in op.writesTo) {
        locals.add(ssa.name);
        if (symbols.containsKey(ssa.name)) {
          symbols[ssa.name]!.add(node);
        } else {
          symbols[ssa.name] = {node};
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
