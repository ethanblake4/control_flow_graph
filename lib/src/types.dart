import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:more/graph.dart';

typedef CFG = Graph<int, void>;

class SpecifiedOperation {
  final int blockId;
  final Operation op;

  SpecifiedOperation(this.blockId, this.op);

  @override
  String toString() => '($blockId, $op)';

  @override
  bool operator ==(Object other) =>
      other is SpecifiedOperation &&
      blockId == other.blockId &&
      identical(op, other.op);

  @override
  int get hashCode => blockId.hashCode ^ identityHashCode(op);
}
