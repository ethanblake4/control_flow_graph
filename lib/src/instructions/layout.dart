import 'instruction.dart';

/// Orders blocks while forwarding unconditional jumps and preserving every
/// original block ID as a label. The input blocks must have explicit jumps for
/// edges that could become non-fallthrough edges after reordering.
/// [branchTarget] reports conditional branch targets; [jumpTarget] reports
/// unconditional jump targets. Both are rewritten through [retargetBranch].
Map<int, List<T>> layoutBlocks<T extends Instruction>(
  Map<int, List<T>> blocks, {
  required int? Function(T instruction) jumpTarget,
  required int? Function(T instruction) branchTarget,
  required T Function(T instruction, int target) retargetBranch,
}) {
  final originalOrder = blocks.keys.toList();
  final redirects = <int, int>{};

  int destination(int target) {
    final path = <int>{};
    while (!redirects.containsKey(target) && path.add(target)) {
      final code = blocks[target]!;
      if (code.length != 1) break;
      final next = jumpTarget(code.single);
      if (next == null) break;
      target = next;
    }
    final result = redirects[target] ?? target;
    for (final id in path) {
      redirects[id] = result;
    }
    return result;
  }

  // Resolve the original jump chains before modifying any instruction list.
  for (final id in originalOrder) {
    destination(id);
  }
  for (final code in blocks.values) {
    for (var i = 0; i < code.length; i++) {
      final target = branchTarget(code[i]) ?? jumpTarget(code[i]);
      if (target != null) {
        code[i] = retargetBranch(code[i], redirects[target]!);
      }
    }
  }

  final aliases = <int, List<int>>{};
  for (final id in originalOrder) {
    final target = redirects[id]!;
    if (id != target) (aliases[target] ??= []).add(id);
  }
  final ordered = <int, List<T>>{};
  for (final start in originalOrder) {
    var id = redirects[start]!;
    while (!ordered.containsKey(id)) {
      final code = blocks[id]!;
      // Keep the old labels at the destination so references outside this
      // instruction stream, such as exception handlers, still resolve.
      for (final alias in aliases[id] ?? const <int>[]) {
        ordered[alias] = [];
      }
      ordered[id] = code;
      if (code.isEmpty) break;
      final next = jumpTarget(code.last);
      if (next == null) break;
      id = next;
    }
  }

  final order = ordered.keys.toList();
  for (var i = 0; i + 1 < order.length; i++) {
    final code = ordered[order[i]]!;
    if (code.isNotEmpty && jumpTarget(code.last) == redirects[order[i + 1]]) {
      code.removeLast();
    }
  }
  return ordered;
}

/// Widens relative branches until every branch fits at its final position.
/// [widen] returns a replacement instruction when [distance] does not fit,
/// or null when the current encoding is sufficient or cannot be widened.
/// A replacement must be longer than the instruction it replaces.
/// The returned offsets include empty alias blocks.
Map<int, int> relaxBranches<T extends Instruction>(
  Map<int, List<T>> blocks, {
  required int Function(T instruction) length,
  required int? Function(T instruction) branchTarget,
  required T? Function(T instruction, int distance) widen,
}) {
  final offsets = <int, int>{};
  bool widened;
  do {
    var offset = 0;
    for (final block in blocks.entries) {
      offsets[block.key] = offset;
      for (final instruction in block.value) {
        offset += length(instruction);
      }
    }
    widened = false;
    offset = 0;
    for (final block in blocks.values) {
      for (var i = 0; i < block.length; i++) {
        final instruction = block[i];
        final instructionLength = length(instruction);
        final target = branchTarget(instruction);
        if (target != null) {
          final distance = offsets[target]! - (offset + instructionLength);
          final replacement = widen(instruction, distance);
          if (replacement != null) {
            if (length(replacement) <= instructionLength) {
              throw StateError(
                  'Branch widening must increase instruction length');
            }
            block[i] = replacement;
            widened = true;
          }
        }
        // Finish this pass with offsets computed from its original lengths.
        offset += instructionLength;
      }
    }
  } while (widened);
  return offsets;
}
