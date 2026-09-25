import 'package:control_flow_graph/control_flow_graph.dart';

/// Replaces uses of copies with their source SSA value. A phi is a copy only
/// when every incoming value resolves to the same definition.
void ssaBasedCopyPropagation(ControlFlowGraph cfg) {
  if (!cfg.inSSAForm) {
    throw StateError('Copy propagation requires SSA form');
  }

  final copies = <SSA, SSA>{};
  SSA resolve(SSA value) {
    final seen = <SSA>{};
    var current = value;
    while (seen.add(current)) {
      final next = copies[current];
      if (next == null) return current;
      current = next;
    }
    return value;
  }

  bool changed;
  do {
    changed = false;
    for (final blockId in cfg.graph.vertices) {
      for (final op in cfg[blockId]!.code) {
        SSA? source;
        if (op is Assign) {
          source = resolve(op.source);
        } else if (op is PhiNode && op.sources.isNotEmpty) {
          final values =
              op.incoming.isEmpty ? op.sources : op.incoming.values.toSet();
          final resolved = values.map(resolve).toSet();
          if (resolved.length == 1) source = resolved.single;
        }
        final target = op.writesTo;
        if (target == null || source == null || source == target) continue;
        if (copies[target] != source) {
          copies[target] = source;
          changed = true;
        }
      }
    }
  } while (changed);
  if (copies.isEmpty) return;

  var rewrittenAny = false;
  for (final blockId in cfg.graph.vertices) {
    final code = cfg[blockId]!.code;
    for (var index = 0; index < code.length; index++) {
      final op = code[index];
      if (op is PhiNode) {
        final sources = {for (final value in op.sources) resolve(value)};
        final incoming = {
          for (final entry in op.incoming.entries)
            entry.key: resolve(entry.value),
        };
        if (sources.length == op.sources.length &&
            sources.containsAll(op.sources) &&
            incoming.length == op.incoming.length &&
            incoming.entries
                .every((entry) => op.incoming[entry.key] == entry.value)) {
          continue;
        }
        code[index] = PhiNode(op.target, sources, incoming: incoming);
      } else {
        final operands = op.operands;
        final rewritten = [for (final value in operands) resolve(value)];
        if (operands.indexed
            .every((entry) => rewritten[entry.$1] == entry.$2)) {
          continue;
        }
        code[index] = op.copyWithOperands(operands: rewritten);
      }
      rewrittenAny = true;
    }
  }
  if (rewrittenAny) cfg.refreshSSA();
}
