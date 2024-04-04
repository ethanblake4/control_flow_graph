import 'package:control_flow_graph/src/types.dart';
import 'package:more/graph.dart';

/// A J-edge in the DJ-graph, representing a non-dominance control flow
/// relationship.
const int jEdge = 0;

/// A D-edge in the DJ-graph, representing a dominance relationship.
const int dEdge = 1;

Graph<int, int> computeDJGraph(CFG graph, Map<int, int> dominators) {
  final djGraph = Graph<int, int>.directed(
      vertexStrategy: StorageStrategy.positiveInteger());

  for (final node in dominators.keys) {
    final idom = dominators[node];
    if (idom != null) {
      djGraph.addEdge(idom, node, value: dEdge);
    }
  }

  for (final node in graph.vertices) {
    for (final successor in graph.successorsOf(node)) {
      if (dominators[successor] != node) {
        djGraph.addEdge(node, successor, value: jEdge);
      }
    }
  }

  return djGraph;
}
