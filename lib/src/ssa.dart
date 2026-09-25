import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/dominators.dart';
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

  ImmediateSSA get imm {
    if (this is ImmediateSSA) {
      return this as ImmediateSSA;
    }
    throw StateError('SSA is not an immediate');
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

class ImmediateSSA extends SSA {
  ImmediateSSA(super.name, this.value, {super.version = -1, super.type = -1});

  factory ImmediateSSA.fromSSA(SSA ssa, Object? value) {
    return ImmediateSSA(ssa.name, value, version: ssa.version, type: ssa.type);
  }

  final Object? value;

  @override
  String toString() {
    return '${super.toString()}=$value';
  }

  @override
  ImmediateSSA copy() {
    return ImmediateSSA(name, value, version: version, type: type);
  }

  @override
  bool operator ==(Object other) {
    return other is ImmediateSSA && super == other && value == other.value;
  }

  @override
  int get hashCode => super.hashCode ^ value.hashCode;
}

/// rename variables, also computing def/use information and SSA graph
///
/// When [copyOperands] is true (the default) every operation is rewritten with
/// fresh operand objects before renaming — required when the frontend shares
/// operand instances between operations, since renaming mutates versions in
/// place. Pass false when the caller has already deep-copied operands (for
/// example a graph produced by a `copyWith`-level deep copy) to skip the
/// extra pass.
SSAComputationData semiPrunedSSARename(
    CFG graph, int root, Map<int, BasicBlock> ids,
    {bool copyOperands = true}) {
  // Operands may be shared by frontend operations. Renaming must never mutate
  // another definition through that alias, nor alias a read to its own result.
  if (copyOperands) {
    for (final blockId in graph.depthFirstPostOrder(root)) {
      final code = ids[blockId]!.code;
      for (var index = 0; index < code.length; index++) {
        final op = code[index];
        code[index] = op.copyWith(
          writesTo: op.writesTo?.copy(),
          readsFrom: {for (final input in op.readsFrom) input.copy()},
        );
      }
    }
  }
  final nextVersions = <String, int>{};
  final blockDefines = <int, Set<SSA>>{};
  final defines = <SSA, SpecifiedOperation>{};
  final uses = <SSA, Set<SpecifiedOperation>>{};
  final ssaGraph = Graph<SpecifiedOperation, void>.directed();
  final dominators = computeDominators(graph, root);
  final children = <int, List<int>>{};
  for (final entry in dominators.entries) {
    if (entry.key != root) {
      children.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    for (final phi in ids[entry.key]!.code.whereType<PhiNode>()) {
      phi.sources.clear();
      phi.incoming.clear();
    }
  }

  // A block inherits only the versions from its immediate dominator. Filling
  // successor phis from the predecessor's outgoing state handles back edges
  // without copying a sibling branch's definitions into the join.
  final worklist = ListQueue<(int, Map<String, int>)>.of([(root, {})]);
  while (worklist.isNotEmpty) {
    final (blockId, incomingVersions) = worklist.removeFirst();
    final versions = {...incomingVersions};
    final block = ids[blockId]!;
    for (final phi in block.code.whereType<PhiNode>()) {
      final name = phi.target.name;
      phi.target.version = versions[name] = nextVersions.update(
        name,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
    }
    for (final op in block.code) {
      if (op is PhiNode) continue;
      for (final input in op.readsFrom) {
        final version = versions[input.name];
        if (version != null) input.version = version;
      }
      final target = op.writesTo;
      if (target != null && !target.name.startsWith('@')) {
        final name = target.name;
        target.version = versions[name] = nextVersions.update(
          name,
          (value) => value + 1,
          ifAbsent: () => 0,
        );
      }
    }
    for (final successor in graph.successorsOf(blockId)) {
      for (final phi in ids[successor]!.code.whereType<PhiNode>()) {
        final name = phi.target.name;
        final source =
            SSA(name, type: phi.target.type, version: versions[name] ?? -1);
        phi.incoming[blockId] = source;
        phi.sources.add(source);
      }
    }
    for (final child in children[blockId] ?? const <int>[]) {
      worklist.add((child, versions));
    }
  }

  // A phi can appear live only because another unused phi reads it. Keep
  // phis reached from real operations, and remove unreferenced phi cycles.
  final phis = <SSA, PhiNode>{};
  for (final blockId in dominators.keys) {
    for (final phi in ids[blockId]!.code.whereType<PhiNode>()) {
      phis[phi.target] = phi;
    }
  }
  final livePhis = <PhiNode>{};
  final pendingPhis = <PhiNode>[];
  for (final blockId in dominators.keys) {
    for (final op in ids[blockId]!.code) {
      if (op is PhiNode) continue;
      for (final input in op.readsFrom) {
        final phi = phis[input];
        if (phi != null) pendingPhis.add(phi);
      }
    }
  }
  while (pendingPhis.isNotEmpty) {
    final phi = pendingPhis.removeLast();
    if (!livePhis.add(phi)) continue;
    for (final input in phi.sources) {
      final dependency = phis[input];
      if (dependency != null) pendingPhis.add(dependency);
    }
  }
  for (final blockId in dominators.keys) {
    ids[blockId]!.code.removeWhere(
          (op) => op is PhiNode && !livePhis.contains(op),
        );
  }

  for (final blockId in dominators.keys) {
    for (final op in ids[blockId]!.code) {
      final spec = SpecifiedOperation(blockId, op);
      final target = op.writesTo;
      if (target != null && !target.name.startsWith('@')) {
        defines[target] = spec;
        blockDefines.putIfAbsent(blockId, () => {}).add(target);
      }
      for (final input in op.readsFrom) {
        uses.putIfAbsent(input, () => Set.identity()).add(spec);
      }
    }
  }
  for (final entry in uses.entries) {
    final definition = defines[entry.key];
    if (definition != null) {
      for (final use in entry.value) {
        ssaGraph.addEdge(definition, use);
      }
    }
  }

  return SSAComputationData(ssaGraph, blockDefines, defines, uses, {
    for (final entry in nextVersions.entries) entry.key: entry.value + 1,
  });
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
