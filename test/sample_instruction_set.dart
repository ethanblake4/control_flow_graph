import 'package:control_flow_graph/control_flow_graph.dart';

import '../example/control_flow_graph_example.dart';

class ContextData {}

/// Load immediate 16-bit integer value into a register
class Imm extends Instruction {
  final int reg;
  final int value;

  Imm(this.reg, this.value);

  static final creator = Creator<LoadImmediate, ContextData>(
    variants: {
      Variant(result: 0),
      Variant(result: 1),
      Variant(result: 2),
    },
    create: (op, context) => Imm(op.writesTo!.alloc.register, op.value),
  );
}
