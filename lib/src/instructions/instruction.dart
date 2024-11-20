import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:control_flow_graph/src/instructions/context.dart';

/// Represents a machine code instruction
class Instruction {}

abstract class InstructionCreator<T extends Operation, C> {
  Set<Variant>? get variants;
  Set<int> get clobberedRegisters;
  Instruction createInstruction(T operation, AssembleContext<C> context);
}

class Variant {
  Variant({
    required this.result,
    this.arguments = const [],
  });
  final int? result;
  final List<int> arguments;
}

class Creator<T extends Operation, C> implements InstructionCreator<T, C> {
  @override
  final Set<int> clobberedRegisters;

  @override
  final Set<Variant> variants;

  final Instruction Function(T operation, AssembleContext<C> context) _create;

  const Creator({
    this.clobberedRegisters = const {},
    required this.variants,
    required Instruction Function(T operation, AssembleContext<C> context)
        create,
  }) : _create = create;

  @override
  Instruction createInstruction(T operation, AssembleContext<C> context) =>
      _create(operation, context);
}
