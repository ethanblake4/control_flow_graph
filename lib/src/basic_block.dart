import 'package:control_flow_graph/src/operation.dart';

/// A basic block is a sequence of operations that are always executed together.
/// Only the last operation may perform control flow (e.g. a branch or jump).
class BasicBlock<T extends Operation> {
  /// The operations in this block. Only the last operation may perform control
  /// flow (e.g. a branch or jump).
  final List<T> code;

  /// The unique identifier of this block in a control flow graph.
  int? id;

  /// An optional label for this block.
  final String? label;

  /// Creates a new basic block with the given [code] and optional [label].
  BasicBlock(this.code, {this.label});

  @override
  String toString() {
    return label == null ? 'B$id' : '$label($id)';
  }

  /// Describes the basic block and its operations.
  String describe() {
    return '$this:\n${code.join('  \n')}';
  }
}
