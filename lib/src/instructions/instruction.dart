import 'package:control_flow_graph/control_flow_graph.dart';

/// Represents a machine code instruction
class Instruction {}

abstract class InstructionCreator<T extends Operation, C> {
  const InstructionCreator();
  Set<Variant>? get variants;
  Set<int> get clobberedRegisters;
  Set<Variant>? variantsFor(T operation) => variants;
  Set<int> clobberedRegistersFor(T operation) => clobberedRegisters;
  Instruction createInstruction(T operation, AssembleContext<C> context);
}

class Variant {
  Variant({
    required this.result,
    this.arguments = const [],
  });

  /// Register index that the instruction writes to, or null if it doesn't write to any register
  final int? result;

  /// List of register indices that the instruction reads from
  final List<int> arguments;
}

class Creator<T extends Operation, C> extends InstructionCreator<T, C> {
  @override
  final Set<int> clobberedRegisters;

  @override
  final Set<Variant> variants;

  final Instruction Function(T operation, AssembleContext<C> context) _create;
  final Set<Variant>? Function(T operation)? selectVariants;
  final Set<int> Function(T operation)? selectClobbers;

  @override
  Set<Variant>? variantsFor(T operation) =>
      selectVariants?.call(operation) ?? variants;
  @override
  Set<int> clobberedRegistersFor(T operation) =>
      selectClobbers?.call(operation) ?? clobberedRegisters;

  const Creator({
    this.clobberedRegisters = const {},
    this.selectVariants,
    this.selectClobbers,
    required this.variants,
    required Instruction Function(T operation, AssembleContext<C> context)
        create,
  }) : _create = create;

  @override
  Instruction createInstruction(T operation, AssembleContext<C> context) =>
      _create(operation, context);
}
