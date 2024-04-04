import 'package:control_flow_graph/control_flow_graph.dart';
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

void iterativeSemiPrunedSSA(ControlFlowGraph cfg) {
  final globals = cfg.globals;
  final djGraph = cfg.djGraph;

  final definitions = globals.keys.toMap(key: (k) => k, value: (_) => 0);
  final versions = {
    for (final entry in definitions.entries) entry.key: {entry.value}
  };

  final visited = <Edge<int, int>>{};
  final Map<int, Map<String, Set<int>>> versionsAtEnd = {};

  void preorderRename(int block, Map<String, Set<int>> versions, bool isDEdge) {
    final remove = <PhiNode>{};
    for (final op in cfg[block]!.code) {
      if (op is PhiNode) {
        final v = op.readsFrom.first;
        final d = definitions[v.name]!;
        if (d == 0) {
          remove.add(op);
          continue;
        }
        final allVersions = versions[v.name]!;
        if (isDEdge) {
          op.sources.clear();
          for (final version in allVersions) {
            op.sources.add(SSA(v.name, version));
          }

          definitions[v.name] = d + 1;
          versions[v.name] = {d};
          op.target.version = d;
        } else {
          var lastVersion = -1;
          for (final version in versions[v.name]!) {
            if (version > lastVersion) {
              lastVersion = version;
            }
          }
          op.sources.add(SSA(v.name, lastVersion));
          versions[v.name] = {op.target.version};
        }

        continue;
      }
      for (final ssa in op.readsFrom) {
        final v = versions[ssa.name];
        if (v == null) {
          continue;
        }
        if (v.length > 1) {
          throw StateError('Variable ${ssa.name} has multiple versions');
        }
        ssa.version = v.first;
      }
      for (final ssa in op.writesTo) {
        final d = definitions[ssa.name];
        if (d == null) {
          continue;
        }
        definitions[ssa.name] = d + 1;
        versions[ssa.name]!.add(d);
        ssa.version = d;
      }
    }

    for (final phi in remove) {
      cfg[block]!.code.remove(phi);
    }

    versionsAtEnd[block] = {...versions};

    for (final edge in djGraph.outgoingEdgesOf(block)) {
      if (visited.add(edge)) {
        preorderRename(edge.target, {...versions}, edge.value == dEdge);
      }
    }
  }

  final rootId = cfg.root.id!;

  visited.add(cfg.djGraph.getEdge(rootId, rootId)!);
  preorderRename(rootId, versions, true);

  for (final mergeSet in cfg.mergeSets.entries) {
    final source = mergeSet.key;
    final targets = mergeSet.value;
    for (final target in targets) {
      for (final phi in cfg[target]!.code) {
        if (phi is! PhiNode) {
          break;
        }
        final nonVersioned = SSA(phi.target.name);
        if (phi.sources.contains(nonVersioned)) {
          phi.sources.remove(nonVersioned);
          final versions = versionsAtEnd[source]![phi.target.name]!;
          final maxVersion = versions.first;
          phi.sources.add(SSA(phi.target.name, maxVersion));
        }
      }
    }
  }
}

String _subscripts = '₀₁₂₃₄₅₆₇₈₉';

String _versionToSubscript(int version) {
  return version.toString().toList().map((c) {
    return _subscripts[int.parse(c)];
  }).join();
}

/// Algorithm on SSA-form graph to find the last assignment to a
/// variable in a block, walking up the graph if necessary.
SSA findVariableInSSAGraph(ControlFlowGraph cfg, int block, String name) {
  final visited = <int>{};
  final stack = [block];

  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (!visited.add(current)) {
      continue;
    }

    for (final op in cfg[current]!.code.reversed) {
      for (final node in op.writesTo) {
        if (node.name == name) {
          return node;
        }
      }
    }

    for (final edge in cfg.djGraph.incomingEdgesOf(current)) {
      stack.add(edge.source);
    }
  }

  throw StateError('Variable $name not found in block $block');
}
