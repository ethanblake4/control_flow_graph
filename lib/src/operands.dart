import 'ssa.dart';

/// Rebuilds ordered operands from corresponding original and renamed inputs.
///
/// The sets must have matching iteration order. Repeated operands retain their
/// positions and multiplicity, including when several positions share a value.
List<SSA> renameOperands(
  List<SSA> operands,
  Set<SSA> original,
  Set<SSA>? renamed,
) {
  if (renamed == null) return operands;
  if (original.length != renamed.length) {
    throw ArgumentError('Operand renaming must preserve the number of inputs');
  }
  final replacements = Map<SSA, SSA>.fromIterables(original, renamed);
  return [for (final operand in operands) replacements[operand]!];
}
