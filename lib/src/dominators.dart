import 'package:control_flow_graph/src/types.dart';
import 'package:more/graph.dart';

Map<int, int> computeDominators(CFG graph, int root) {
  final postorder = graph.depthFirstPostOrder(root).toList();
  var i = 0;
  final postorderNumber = <int, int>{for (final node in postorder) node: i++};
  final reversePostorder = postorder.reversed.toList();

  final doms = <int, int?>{for (final node in reversePostorder) node: null};

  doms[root] = root;

  int? intersect(int? n1, int? n2) {
    int? finger1 = n1;
    int? finger2 = n2;
    while (finger1 != finger2) {
      while (postorderNumber[finger1]! < postorderNumber[finger2]!) {
        finger1 = doms[finger1];
      }
      while (postorderNumber[finger2]! < postorderNumber[finger1]!) {
        finger2 = doms[finger2];
      }
    }
    return finger1;
  }

  var changed = true;
  while (changed) {
    changed = false;
    for (final node in reversePostorder) {
      if (node == root) {
        continue;
      }
      final predecessors = graph
          .predecessorsOf(node)
          .where((predecessor) => doms[predecessor] != null)
          .toList();
      int? newIdom = predecessors.firstOrNull;
      for (final predecessor in predecessors.skip(1)) {
        if (doms[predecessor] != null) {
          newIdom = intersect(predecessor, newIdom);
        }
      }
      if (doms[node] != newIdom) {
        doms[node] = newIdom;
        changed = true;
      }
    }
  }

  return doms.cast<int, int>();
}

Graph<int, void> createDominatorTree(
  Map<int, int?> dominators,
) {
  final tree = Graph<int, void>.directed(
      vertexStrategy: StorageStrategy.positiveInteger());
  for (final node in dominators.keys) {
    final idom = dominators[node];
    if (idom != null) {
      tree.addEdge(idom, node);
    }
  }
  return tree;
}
