import 'dart:collection';

import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/allocator/regalloc_2.dart';
import 'package:control_flow_graph/src/allocator/register_pressure.dart';
import 'package:control_flow_graph/src/allocator/spill.dart';
import 'package:control_flow_graph/src/dj_graph.dart';
import 'package:control_flow_graph/src/dominators.dart';
import 'package:control_flow_graph/src/globals.dart';
import 'package:control_flow_graph/src/liveness.dart';
import 'package:control_flow_graph/src/loop.dart';
import 'package:control_flow_graph/src/merge_set.dart';
import 'package:control_flow_graph/src/next_use.dart';
import 'package:control_flow_graph/src/operation.dart';
import 'package:control_flow_graph/src/optimizations/copy_propagation.dart';
import 'package:control_flow_graph/src/optimizations/dce.dart';
import 'package:control_flow_graph/src/phi.dart';
import 'package:control_flow_graph/src/ssa.dart';
import 'package:control_flow_graph/src/types.dart';
import 'package:more/more.dart';

/// Represents a control flow graph operating on basic blocks of
/// SSA operations.
class ControlFlowGraph {
  /// The underlying directed graph structure. If you modify this graph
  /// directly, you must call [invalidate] to reset the internal caches.
  final CFG graph;

  /// Root block of the control flow graph
  late final BasicBlock root;

  /// Map of labels to block IDs
  final Map<String, int> labels = {};
  final Map<int, BasicBlock> _ids = {};

  /// Map of type IDs to RegTypes
  final Map<int, RegType> regTypes = {};

  /// Loops
  final Set<Loop> loops = {};

  /// Op creators
  final Map<Type, InstructionCreator> opCreators = {};

  /// Last block ID assigned
  int lastBlockId = 0;

  bool _hasPhiNodes = false;

  /// Whether the control flow graph has had Phi nodes inserted (by calling
  /// [insertPhiNodes]).
  bool get hasPhiNodes => _hasPhiNodes;

  bool _inSSAForm = false;

  /// Whether the control flow graph is in SSA form (after calling
  /// [computeSemiPrunedSSA]).
  bool get inSSAForm => _inSSAForm;

  /// Creates a new control flow graph.
  ControlFlowGraph()
      : graph = Graph<int, void>.directed(
            vertexStrategy: StorageStrategy.positiveInteger());

  /// Create a new declarative control flow graph builder.
  static ControlFlowGraphBuilder builder() => ControlFlowGraphBuilder();

  /// Magic constant. Assign a boolean value to this SSA to indicate the taking
  /// a conditional branch.
  static final SSA branch = SSA('@branch');

  /// Register a RegType for the given type ID.
  void registerRegType(int id, RegType type) {
    regTypes[id] = type;
  }

  /// Link the end of [source] to the start of [target]. If the blocks are not
  /// already part of the graph, they will be added.
  void link(BasicBlock source, BasicBlock target) {
    if (hasPhiNodes) {
      throw StateError('Cannot link blocks after adding phi nodes');
    }
    if (inSSAForm) {
      throw StateError('Cannot link blocks after converting to SSA form');
    }

    final sid = source.id ??= lastBlockId++;
    final tid = target.id ??= lastBlockId++;
    if (source.label != null) {
      labels[source.label!] = sid;
    }
    if (target.label != null) {
      labels[target.label!] = tid;
    }
    _ids[sid] = source;
    _ids[tid] = target;
    graph.addEdge(sid, tid);
    invalidate();
  }

  /// Link all blocks in [source] to all blocks in [target]. If the blocks are
  /// not already part of the graph, they will be added.
  void linkAll(Iterable<BasicBlock> source, Iterable<BasicBlock> target) {
    if (hasPhiNodes) {
      throw StateError('Cannot link blocks after adding phi nodes');
    }
    if (inSSAForm) {
      throw StateError('Cannot link blocks after converting to SSA form');
    }
    for (final s in source) {
      for (final t in target) {
        final sid = s.id ??= lastBlockId++;
        final tid = t.id ??= lastBlockId++;

        if (s.label != null) {
          labels[s.label!] = sid;
        }

        if (t.label != null) {
          labels[t.label!] = tid;
        }
        _ids[sid] = s;
        _ids[tid] = t;
        graph.addEdge(sid, tid);
      }
    }
    invalidate();
  }

  /// Link the end of the block with [source] label to the start of the block
  /// with [target] label.
  void linkLabel(String source, String target) {
    if (hasPhiNodes) {
      throw StateError('Cannot link blocks after adding phi nodes');
    }
    if (inSSAForm) {
      throw StateError('Cannot link blocks after converting to SSA form');
    }
    graph.addEdge(labels[source]!, labels[target]!);
    invalidate();
  }

  /// Link all blocks with [source] label to all blocks with [target] label.
  void linkAllLabel(Iterable<String> source, Iterable<String> target) {
    if (hasPhiNodes) {
      throw StateError('Cannot link blocks after adding phi nodes');
    }
    if (inSSAForm) {
      throw StateError('Cannot link blocks after converting to SSA form');
    }
    for (final s in source) {
      for (final t in target) {
        graph.addEdge(labels[s]!, labels[t]!);
      }
    }
    invalidate();
  }

  /// Append a block without linking it to any other block.
  void append(BasicBlock block, [bool override = false]) {
    if (hasPhiNodes && !override) {
      throw StateError('Cannot append blocks after adding phi nodes');
    }
    if (inSSAForm && !override) {
      throw StateError('Cannot append blocks after converting to SSA form');
    }
    final id = block.id ??= lastBlockId++;
    if (block.label != null) {
      labels[block.label!] = id;
    }
    _ids[id] = block;
    graph.addVertex(id);
    if (!override) invalidate();
  }

  /// Invalidate all internal caches. This is necessary if you modify the graph
  /// directly.
  void invalidate() {
    _globals = null;
    _dominators = null;
    _dominatorTree = null;
    _djGraph = null;
    _mergeSets = null;
    blockDefines = null;
    uses = null;
    _liveoutMsCache.clear();
  }

  /// Get the basic block with the given ID or label.
  BasicBlock? operator [](Object id) {
    if (id is int) {
      return _ids[id];
    } else if (id is String) {
      return _ids[labels[id]];
    }
    return null;
  }

  Map<String, Set<int>>? _globals;

  /// Get computed globals in the control flow graph. Globals are all variables
  /// that are written to in one block and read from in another.
  Map<String, Set<int>> get globals =>
      _globals ??= calculateGlobals(graph, _ids, root.id!);

  Map<int, int>? _dominators;

  /// Get the immediate dominators of each block in the control flow graph.
  /// The root block has itself as the dominator.
  Map<int, int> get dominators =>
      _dominators ??= computeDominators(graph, root.id!);

  Graph<int, void>? _dominatorTree;

  /// Get the dominator tree of the control flow graph. The dominator tree is a
  /// tree where each node is the immediate dominator of its children.
  Graph<int, void> get dominatorTree =>
      _dominatorTree ??= createDominatorTree(dominators);

  Graph<int, int>? _djGraph;

  /// Get computed DJ-graph of the control flow graph. The DJ-graph is a
  /// directed graph with D-edges, which link immediate dominators to their
  /// children, and J-edges, representing jumps in the control flow between
  /// blocks that are not immediate dominators.
  Graph<int, int> get djGraph => _djGraph ??= computeDJGraph(graph, dominators);

  Map<int, Set<int>>? _mergeSets;

  /// Get computed merge sets of the control flow graph. A merge set of a block
  /// is the set of all blocks where its control flow can 'merge' with a
  /// different path.
  Map<int, Set<int>> get mergeSets => _mergeSets ??=
      completeTopDownMergeSetComputation(djGraph, root.id!, dominators);

  /// Specifies all SSA variables defined in each block. Only available after
  /// converting to SSA form.
  Map<int, Set<SSA>>? blockDefines;

  /// Max version of each SSA variable.
  Map<String, int> maxVersions = {};

  // Defines of each SSA variable in the control flow graph. Only available
  // after converting to SSA form.
  Map<SSA, SpecifiedOperation>? defines;

  /// Uses of each SSA variable in the control flow graph. Only available
  /// after converting to SSA form.
  Map<SSA, Set<SpecifiedOperation>>? uses;

  Map<int, Map<SSA, SplayTreeSet<int>>>? _nextUseDistances;

  Map<int, Map<SSA, SplayTreeSet<int>>> get nextUseDistances {
    if (!inSSAForm) {
      throw StateError(
          'Cannot access next use distances before converting to SSA form');
    }
    return _nextUseDistances ??= computeGlobalNextUseDistances(this, graph,
        root.id!, _ids, blockDefines!, uses!, regTypes, loops, dominators);
  }

  /// Get the computed register pressure for each block in the control flow
  /// graph. Only available after converting to SSA form.
  Map<int, Map<RegisterGroup, int>> get registerPressure {
    if (!inSSAForm) {
      throw StateError(
          'Cannot access register pressure before converting to SSA form');
    }
    return computeRegisterPressure(graph, root.id!, _ids, regTypes,
        blockDefines!, uses!, dominators, mergeSets);
  }

  /// SSA graph. Only available after converting to SSA form.
  Graph<SpecifiedOperation, void> get ssaGraph {
    if (!inSSAForm) {
      throw StateError('Cannot access SSA graph before converting to SSA form');
    }
    return _ssaGraph!;
  }

  Graph<SpecifiedOperation, void>? _ssaGraph;

  final Map<int, Set<int>> _liveoutMsCache = {};

  /// Print the computed merge sets in a readable format.
  void printMergeSets() {
    final sorted = mergeSets.entries
        .toSortedList(comparator: (a, b) => a.key.compareTo(b.key));
    for (final entry in sorted) {
      print('${entry.key}: ${entry.value.map((b) => b.toString()).toList()}');
    }
  }

  /// Insert Phi nodes into the control flow graph. This is necessary before
  /// converting the control flow graph to SSA form.
  void insertPhiNodes() {
    if (hasPhiNodes) {
      throw StateError('Already inserted phi nodes');
    }
    if (inSSAForm) {
      throw StateError('Cannot insert phi nodes into SSA form');
    }
    insertPhiNodesInto(_ids, globals, mergeSets);
    _hasPhiNodes = true;
  }

  /// Convert the control flow graph to semi-pruned SSA form.
  void computeSemiPrunedSSA() {
    if (!hasPhiNodes) {
      throw StateError('Must insert phi nodes before converting to SSA form');
    }
    if (inSSAForm) {
      throw StateError('Already in SSA form');
    }
    final ssaData = semiPrunedSSARename(graph, root.id!, _ids, globals);

    blockDefines = ssaData.blockDefines;
    defines = ssaData.defines;
    uses = ssaData.uses;
    _ssaGraph = ssaData.ssaGraph;
    maxVersions = ssaData.definitions;

    _inSSAForm = true;
  }

  void convertToConventionalForm() {
    if (!inSSAForm) {
      throw StateError('Cannot convert to conventional SSA form');
    }
    makeConventional(this, root.id!, _ids);
  }

  /// Query live-in variable information for a block. Must be in SSA form.
  bool isLiveIn(SSA variable, BasicBlock block) {
    if (!inSSAForm) {
      throw StateError('Cannot query live-in variables in non-SSA form');
    }
    return isLiveInUsingMergeSet(root.id!, block.id!, variable, blockDefines!,
        uses!, dominators, mergeSets);
  }

  /// Query live-out variable information for a block. Must be in SSA form.
  bool isLiveOut(SSA variable, BasicBlock block) {
    if (!inSSAForm) {
      throw StateError('Cannot query live-out variables in non-SSA form');
    }
    return isLiveOutUsingMergeSet(block.id!, variable, graph, blockDefines!,
        uses!, dominators, mergeSets, _liveoutMsCache);
  }

  Map<int, Set<SSA>> get allLiveIn {
    if (!inSSAForm) {
      throw StateError('Cannot access live-in variables in non-SSA form');
    }
    return allLiveInUsingMergeSet(
        root.id!, graph, blockDefines!, uses!, dominators, mergeSets);
  }

  Map<int, Set<SSA>> get allLiveOut {
    if (!inSSAForm) {
      throw StateError('Cannot access live-out variables in non-SSA form');
    }
    return allLiveOutUsingMergeSet(
        root.id!, graph, blockDefines!, uses!, dominators, mergeSets);
  }

  /// Find the current version of a variable in a block. Must be in SSA form.
  SSA findSSAVariable(BasicBlock block, String name) {
    if (!inSSAForm) {
      throw StateError('Cannot find variable in non-SSA form');
    }
    return findVariableInSSAGraph(_ids, djGraph, block.id!, name);
  }

  void runCopyPropagation() {
    if (!inSSAForm) {
      throw StateError('Cannot run copy propagation in non-SSA form');
    }
    ssaBasedCopyPropagation(this, root.id!);
  }

  void removeUnusedDefines() {
    if (!inSSAForm) {
      throw StateError('Cannot remove unused defines in non-SSA form');
    }
    removeUnusedSSADefines(this);
  }

  void removeEmptyAndUnusedBlocks() {
    if (!inSSAForm) {
      throw StateError('Cannot remove empty blocks in non-SSA form');
    }
    trimBlocks(this);
  }

  void spillReloadVariables(Map<RegisterGroup, int> registerCounts) {
    if (!inSSAForm) {
      throw StateError('Cannot spill/reload variables in non-SSA form');
    }
    final reloads = <SSA>{};
    Operation sp(SSA ssa) => SpillNode(ssa);
    Operation re(SSA ssa) {
      reloads.add(ssa);
      return ReloadNode(ssa);
    }

    spill(graph, root.id!, _ids, loops, regTypes, registerCounts,
        registerPressure, nextUseDistances, uses!, allLiveIn, sp, re);
  }

  void goAllocateRegisters(Map<RegisterGroup, int> registerCounts) {
    if (!inSSAForm) {
      throw StateError('Cannot spill/reload variables in non-SSA form');
    }
    Operation sp(SSA ssa) => SpillNode(ssa);
    Operation re(SSA ssa) {
      return ReloadNode(ssa);
    }

    Operation copy(SSA dst, SSA src) => Assign(dst, src);
    regalloc(
        graph,
        root.id!,
        _ids,
        loops,
        regTypes,
        opCreators,
        registerCounts,
        registerPressure,
        nextUseDistances,
        uses!,
        allLiveIn,
        allLiveOut,
        sp,
        re,
        copy);
  }

  /// Remove Phi nodes from the control flow graph, replacing them with normal
  /// assignment operations.
  void removePhiNodes(Operation Function(SSA left, SSA right) assign) {
    if (!hasPhiNodes) {
      throw StateError('No phi nodes to remove');
    }
    if (!inSSAForm) {
      throw StateError('Cannot remove phi nodes from non-SSA form');
    }
    removePhiNodesFrom(graph, ssaGraph, _ids, root.id!, assign);
    _hasPhiNodes = false;
    //_inSSAForm = false;
  }

  @override
  String toString() {
    final sb = StringBuffer();
    for (final b in graph.breadthFirst(root.id!)) {
      sb.writeln(_ids[b]!.describe());
      final outgoing =
          graph.outgoingEdgesOf(b).map((e) => this[e.target]).join(', ');
      if (outgoing.isNotEmpty) {
        if (outgoing.length > 1) {
          sb.writeln('→ ($outgoing)\n');
        } else {
          sb.writeln('→ $outgoing\n');
        }
      }
    }
    return sb.toString();
  }
}

class ControlFlowGraphBuilder {
  ControlFlowGraphBuilder();

  BasicBlockBuilder root(BasicBlock root) {
    final cfg = ControlFlowGraph();
    root.id = cfg.lastBlockId++;
    return BasicBlockBuilder(cfg, [root], null);
  }
}
