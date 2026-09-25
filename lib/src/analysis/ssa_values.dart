import '../cfg.dart';
import '../operation.dart';
import '../ssa.dart';

/// Propagates a value across SSA names required to agree by copies or phi nodes.
/// The caller supplies the meaning of [T] and which names must agree.
class SSAValueConstraints<T extends Object> {
  final Map<SSA, T> _values = {};
  final List<List<SSA>> _equalities = [];

  void constrain(SSA value, T fact) {
    final previous = _values[value];
    if (previous != null && previous != fact) {
      throw StateError('Conflicting values for $value: $previous and $fact');
    }
    _values[value] = fact;
  }

  void equate(Iterable<SSA> values) {
    _equalities.add(values.toList());
  }

  /// Returns all known values after copying each fact through its equalities.
  Map<SSA, T> solve() {
    bool changed;
    do {
      changed = false;
      for (final equality in _equalities) {
        T? known;
        for (final value in equality) {
          final fact = _values[value];
          if (fact == null) continue;
          if (known != null && known != fact) {
            throw StateError(
              'Conflicting values for ${equality.join(', ')}: '
              '$known and $fact',
            );
          }
          known = fact;
        }
        if (known == null) continue;
        for (final value in equality) {
          if (!_values.containsKey(value)) changed = true;
          _values[value] = known;
        }
      }
    } while (changed);
    return Map.unmodifiable(_values);
  }
}

/// Looks up SSA definitions in the current graph code, without relying on
/// cached def-use metadata that an IR rewrite may have invalidated.
class SSADefinitions {
  SSADefinitions(ControlFlowGraph graph)
      : _definitions = {
          for (final id in graph.graph.vertices)
            for (final op in graph[id]!.code)
              if (op.writesTo case final target?) target: op,
        };

  final Map<SSA, Operation> _definitions;

  Operation? operator [](SSA value) => _definitions[value];

  /// Resolves assignments to the operation that originally defined [value].
  /// Returns null for a copy cycle or an undefined name.
  Operation? throughCopies(SSA value) {
    final seen = <SSA>{};
    while (seen.add(value)) {
      final op = _definitions[value];
      if (op is! Assign) return op;
      value = op.source;
    }
    return null;
  }
}
