import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

/// A static single assignment (SSA) form variable.
class SSA {
  /// The name of the variable.
  final String name;

  /// The version of the variable.
  int version;

  /// Creates a new SSA variable with the given [name] and optional [version].
  /// Typically you should not assign a version directly. Versions will be
  /// assigned automatically during SSA transformation.
  SSA(this.name, [this.version = -1]);

  @override
  String toString() {
    return '$name${version == -1 ? '' : _versionToSubscript(version)}';
  }

  @override
  bool operator ==(Object other) {
    return other is SSA && name == other.name && version == other.version;
  }

  @override
  int get hashCode => name.hashCode ^ version.hashCode;
}

/// rename variables, also computing def/use information and SSA graph
SSAComputationData semiPrunedSSARename(CFG graph, int root,
    Map<int, BasicBlock> ids, Map<String, Set<int>> globals) {
  final definitions = globals.keys.toMap(key: (k) => k, value: (_) => 0);
  final visited = <int>{};
  final worklist = ListQueue<(int, Map<String, int>)>.of([
    (root, {for (final entry in definitions.entries) entry.key: entry.value})
  ]);

  final blockDefines = <int, Set<SSA>>{};
  final defines = <SSA, SpecifiedOperation>{};
  final uses = <SSA, Set<SpecifiedOperation>>{};
  final ssaGraph = Graph<SpecifiedOperation, void>.directed();

  workloop:
  while (worklist.isNotEmpty) {
    final workItem = worklist.removeFirst();
    final (blockId, versions) = workItem;
    final unseen = visited.add(blockId);
    final block = ids[blockId]!;
    var remove = <PhiNode>[];

    for (final op in block.code) {
      final spec = SpecifiedOperation(blockId, op);
      if (op is PhiNode) {
        final v = op.sources.first;
        final d = definitions[v.name]!;
        final version = versions[v.name]!;
        if (unseen) {
          op.sources.clear();
          if (d == 0) {
            remove.add(op);
          } else {
            definitions[v.name] = d + 1;
            final target = op.target;
            target.version = versions[v.name] = d;
            defines[target] = spec;
            blockDefines.putIfAbsent(blockId, () => {}).add(target);
          }
        }
        final src = SSA(v.name, version);
        op.sources.add(src);
        uses.putIfAbsent(src, () => Set.identity()).add(spec);
        final def = defines[src];
        if (def != null) {
          ssaGraph.addEdge(def, spec);
        }

        continue;
      }

      if (!unseen) {
        continue workloop;
      }

      final writesTo = op.writesTo;

      for (final ssa in op.readsFrom) {
        final v = versions[ssa.name];
        if (v != null) {
          ssa.version = v;
          uses.putIfAbsent(ssa, () => Set.identity()).add(spec);
        }
        if (writesTo != null) {
          final def = defines[ssa];
          if (def != null) {
            ssaGraph.addEdge(def, spec);
          }
        }
      }

      if (writesTo != null) {
        final d = definitions[writesTo.name];
        if (d != null) {
          definitions[writesTo.name] = d + 1;
          versions[writesTo.name] = d;
          writesTo.version = d;
          defines[writesTo] = spec;
          blockDefines.putIfAbsent(blockId, () => {}).add(writesTo);
        }
      }
    }

    for (final op in remove) {
      block.code.remove(op);
    }

    for (final next in graph.successorsOf(blockId)) {
      worklist.add((next, {...versions}));
    }
  }

  return SSAComputationData(ssaGraph, blockDefines, defines, uses);
}

String _subscripts = '₀₁₂₃₄₅₆₇₈₉';

String _versionToSubscript(int version) {
  return version.toString().toList().map((c) {
    return _subscripts[int.parse(c)];
  }).join();
}

/// Algorithm on SSA-form graph to find the last assignment to a
/// variable in a block, walking up the graph if necessary.
SSA findVariableInSSAGraph(
    Map<int, BasicBlock> ids, Graph<int, int> djGraph, int block, String name) {
  final visited = <int>{};
  final stack = [block];

  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (!visited.add(current)) {
      continue;
    }

    for (final op in ids[current]!.code.reversed) {
      final writesTo = op.writesTo;
      if (writesTo != null) {
        if (writesTo.name == name) {
          return writesTo;
        }
      }
    }

    for (final vertex in djGraph.predecessorsOf(current)) {
      stack.add(vertex);
    }
  }

  throw StateError('Variable $name not found in block $block');
}

class SSAComputationData {
  final Graph<SpecifiedOperation, void> ssaGraph;
  final Map<int, Set<SSA>> blockDefines;
  final Map<SSA, SpecifiedOperation> defines;
  final Map<SSA, Set<SpecifiedOperation>> uses;

  SSAComputationData(this.ssaGraph, this.blockDefines, this.defines, this.uses);
}
