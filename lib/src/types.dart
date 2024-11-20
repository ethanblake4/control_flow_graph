import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:more/graph.dart';

typedef CFG = Graph<int, void>;

class RegisterGroup {
  final Set<int> registers;

  RegisterGroup(this.registers);

  @override
  String toString() => registers.toString();

  @override
  bool operator ==(Object other) =>
      other is RegisterGroup && registers == other.registers;

  @override
  int get hashCode => registers.hashCode;
}

class RegType {
  final int id;
  final String name;
  final Set<RegisterGroup> regGroups;

  const RegType(this.id, this.name, this.regGroups);

  @override
  String toString() => name;
}

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
