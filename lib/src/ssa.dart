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

  /// The type of the variable.
  int type;

  /// Creates a new SSA variable with the given [name] and optional [version].
  /// Typically you should not assign a version directly. Versions will be
  /// assigned automatically during SSA transformation.
  SSA(this.name, {this.version = -1, this.type = -1});

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

  SSA copy() {
    return SSA(name, type: type, version: version);
  }

  AllocatedSSA get alloc {
    if (this is AllocatedSSA) {
      return this as AllocatedSSA;
    }
    throw StateError('SSA is not allocated');
  }
}

class AllocatedSSA extends SSA {
  AllocatedSSA(super.name, this.register,
      {super.version = -1, super.type = -1});

  factory AllocatedSSA.fromSSA(SSA ssa, int register) {
    return AllocatedSSA(ssa.name, register,
        version: ssa.version, type: ssa.type);
  }

  final int register;

  @override
  String toString() {
    return '${super.toString()}→$register';
  }

  @override
  AllocatedSSA copy() {
    return AllocatedSSA(name, register, version: version, type: type);
  }

  @override
  bool operator ==(Object other) {
    return other is AllocatedSSA &&
        super == other &&
        register == other.register;
  }

  @override
  int get hashCode => super.hashCode ^ register.hashCode;
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
    final (blockId, versions) = worklist.removeFirst();
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
        final src = SSA(v.name, type: v.type, version: version);
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
        var v = versions[ssa.name];
        if (v == null && !ssa.name.startsWith('@')) {
          definitions[ssa.name] = versions[ssa.name] = v = 0;
        }
        if (v != null) {
          ssa.version = v;
        }
        uses.putIfAbsent(ssa, () => Set.identity()).add(spec);
        if (writesTo != null) {
          final def = defines[ssa];
          if (def != null) {
            ssaGraph.addEdge(def, spec);
          }
        }
      }

      if (writesTo != null) {
        var d = definitions[writesTo.name] ?? 0;
        if (!writesTo.name.startsWith('@')) {
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

  return SSAComputationData(ssaGraph, blockDefines, defines, uses, definitions);
}

/*
Algorithm 3.5: Critical edge splitting algorithm for making non-conventional
SSA form conventional
1 foreach B: basic block of the CFG do
2   let (E1,...,En) be the list of incoming edges of B
3   foreach Ei = (Bi,B) do
4     let PCi be an empty parallel copy instruction
5     if Bi has several outgoing edges then
6       create fresh empty basic block Bi
7       replace edge Ei by edges Bi → Bi' and Bi' → B
8       insert PCi in Bi'
9     else
10      append PCi at the end of Bi
11   foreach φ-function at the entry of B of the form a0 = φ(B1 : a1,...,Bn : an) do
12     foreach ai (argument of the φ-function corresponding to Bi) do
13       let ai' be a freshly created variable
14       add copy ai' ← ai to PCi
15       replace ai by ai' in the φ-function
*/
void makeConventional(
    ControlFlowGraph cfg, int root, Map<int, BasicBlock> ids) {
  final traversal = cfg.graph.depthFirst(root);

  for (final blockId in traversal) {
    final block = ids[blockId]!;
    final incoming = cfg.graph.predecessorsOf(blockId);
    final pc = ParallelCopy();

    for (final from in incoming) {
      final outgoingEdges = cfg.graph.successorsOf(from);
      final severalOutgoingEdges = outgoingEdges.length > 1;

      if (severalOutgoingEdges) {
        final newBlock = BasicBlock<Operation>([pc]);
        cfg.append(newBlock, true);
        cfg.graph.addEdge(newBlock.id!, blockId);
        cfg.graph.removeEdge(from, blockId);
        cfg.graph.addEdge(from, newBlock.id!);
      } else {
        block.code.add(pc);
      }
    }

    for (final op in block.code) {
      if (op is PhiNode) {
        final sources = op.sources;
        for (final source in {...sources}) {
          final newSource = SSA(source.name,
              type: source.type, version: source.version + 100000);
          pc.copies.add((newSource, source));
          sources.remove(source);
          sources.add(newSource);
        }
      }
    }
  }
}

String _subscripts = '₀₁₂₃₄₅₆₇₈₉';

String _versionToSubscript(int version) {
  final vi = version >= 100000;
  final ver = vi ? version - 100000 : version;
  return ver.toString().toList().map((c) {
        return _subscripts[int.parse(c)];
      }).join() +
      (vi ? '₊' : '');
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
  Map<String, int> definitions;

  SSAComputationData(this.ssaGraph, this.blockDefines, this.defines, this.uses,
      this.definitions);
}
