class AssembleContext<T> {
  final T data;

  /// The block ID of the block currently being assembled.
  /// Set by the assembler before processing each block's operations.
  int currentBlockId = 0;

  /// The block IDs of the successors of [currentBlockId], in edge-insertion
  /// order.  For a conditional branch the first entry is the "true" target
  /// and the second is the "false" / fall-through target.
  List<int> successorBlockIds = const [];

  AssembleContext(this.data);
}
