import 'package:control_flow_graph/src/dj_graph.dart';
import 'package:more/graph.dart';

/// ### Algorithm: Top Down Merge Set Computation (TDMSC-I)
/// #### Input : GDJ
/// #### Outputs:
/// - Partial/Complete Merge sets for every node of the DJ Graph
/// - A boolean value to indicate whether a subsequent pass is required
bool _topDownMergeSetComputation(
    Map<int, Set<int>> mergeSets,
    Graph<int, int> djGraph,
    List<int> djGraphInBreadthFirstOrder,
    int root,
    Map<int, int> dominators) {
  var requireAnotherPass = false;
  final visited = <Edge<int, int>>{};

  Map<int, int> level = {};
  for (final node in djGraphInBreadthFirstOrder) {
    final ldom = level[dominators[node]];
    level[node] = ldom == null ? 0 : ldom + 1;
  }

  for (final node in djGraphInBreadthFirstOrder) {
    for (final incomingEdge in djGraph.incomingEdgesOf(node)) {
      if (incomingEdge.value == jEdge && !visited.contains(incomingEdge)) {
        visited.add(incomingEdge);
        final sourceNode = incomingEdge.source;
        final targetNode = incomingEdge.target;
        var tmp = sourceNode;
        int? lnode;
        while (level[tmp]! >= level[targetNode]!) {
          final mergeSet = mergeSets[tmp];
          final targetMergeSet = mergeSets[targetNode];
          mergeSets[tmp] = {
            if (mergeSet != null) ...mergeSet,
            if (targetMergeSet != null) ...targetMergeSet,
            targetNode
          };
          lnode = tmp;
          final dom = dominators[tmp]!;
          if (dom == tmp) {
            break;
          }
          tmp = dom;
        }
        for (final incomingEdgeToLNode in djGraph.incomingEdgesOf(lnode!)) {
          if (incomingEdgeToLNode.value == jEdge &&
              visited.contains(incomingEdgeToLNode)) {
            final sourceNodeToLNode = incomingEdgeToLNode.source;
            if (!mergeSets[sourceNodeToLNode]!.containsAll(mergeSets[lnode]!)) {
              var node = sourceNodeToLNode;
              while (level[node]! >= (level[lnode] ?? 0)) {
                mergeSets[node] = {
                  ...mergeSets[node]!,
                  if (lnode != null) ...mergeSets[lnode]!
                };
                lnode = node;
                node = dominators[node]!;
              }
              if (_isIncomingJEdgeInconsistent(
                  mergeSets, djGraph, visited, lnode!)) {
                requireAnotherPass = true;
              }
            }
          }
        }
      }
    }
  }
  return requireAnotherPass;
}

/// An Incoming J Edge Inconsistent(x) is true if at least one of the incoming
/// J-edges to x is inconsistent, false otherwise.
bool _isIncomingJEdgeInconsistent(Map<int, Set<int>> mergeSets,
    Graph<int, int> djGraph, Set<Edge<int, int>> visited, int node) {
  for (final incomingEdge in djGraph.incomingEdgesOf(node)) {
    if (incomingEdge.value == jEdge && visited.contains(incomingEdge)) {
      final sourceNode = incomingEdge.source;
      final targetNode = incomingEdge.target;
      if (!mergeSets[sourceNode]!.containsAll(mergeSets[targetNode]!)) {
        return true;
      }
    }
  }
  return false;
}

/// ### Algorithm: Complete Top Down Merge Set Computation (CTDMSC)
/// #### Input: GDJ
/// #### Output: Complete Merge sets for every node of the DJ graph
Map<int, Set<int>> completeTopDownMergeSetComputation(
    Graph<int, int> djGraph, int root, Map<int, int> dominators) {
  final mergeSets = <int, Set<int>>{};
  var requireAnotherPass = true;
  final djGraphInBreadthFirstOrder = djGraph.breadthFirst(root).toList();
  while (requireAnotherPass) {
    requireAnotherPass = _topDownMergeSetComputation(
        mergeSets, djGraph, djGraphInBreadthFirstOrder, root, dominators);
  }
  return mergeSets;
}
