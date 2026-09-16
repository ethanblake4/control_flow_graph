import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:more/more.dart';
import 'package:control_flow_graph/src/operation.dart';
import 'package:control_flow_graph/src/types.dart';

/// Allocates constrained instructions, retaining block-local register contents
/// and backing evicted live values with canonical SSA spill slots.
void allocateConstrained(CFG graph, int root, Map<int, BasicBlock> blocks,
    Map<int, RegType> types, Map<Type, InstructionCreator> creators) {
  final order = graph.depthFirstPostOrder(root).toList().reversed.toList();
  final positions = {for (var i = 0; i < order.length; i++) order[i]: i};
  final liveIn = <int, Set<SSA>>{for (final id in order) id: {}};
  final liveOut = <int, Set<SSA>>{for (final id in order) id: {}};
  bool changed;
  do {
    changed = false;
    for (final id in order.reversed) {
      final outgoing = <SSA>{
        for (final next in graph.successorsOf(id)) ...liveIn[next]!
      };
      final incoming = {...outgoing};
      for (final op in blocks[id]!.code.reversed) {
        if (op.writesTo != null) incoming.remove(op.writesTo);
        incoming.addAll(_inputs(op));
      }
      if (!_same(incoming, liveIn[id]!) || !_same(outgoing, liveOut[id]!)) {
        liveIn[id] = incoming;
        liveOut[id] = outgoing;
        changed = true;
      }
    }
  } while (changed);
  final carried = <int, _BlockAllocator>{};
  for (final id in order) {
    final predecessor = carried.remove(id);
    final allocator = _BlockAllocator(
        types, creators, predecessor?.stored ?? liveIn[id]!, liveOut[id]!);
    if (predecessor != null) {
      allocator.residents.addAll(predecessor.residents);
    }
    final successors = graph.successorsOf(id).toList();
    final normalEdges = successors.length == 1 ||
        (blocks[id]!.code.lastOrNull?.isConditionalBranch ?? false);
    final carry = {
      if (normalEdges)
        for (final next in successors)
          if (graph.predecessorsOf(next).length == 1 &&
              positions[next]! > positions[id]!)
            next,
    };
    final boundaryValues = <SSA>{
      for (final next in successors)
        if (!carry.contains(next)) ...liveIn[next]!,
    };
    final code =
        allocator.allocate(blocks[id]!.code, boundaryValues: boundaryValues);
    blocks[id]!.code
      ..clear()
      ..addAll(code);
    // Each child allocator copies these collections before changing them.
    // Both branch alternatives therefore see the same predecessor state.
    for (final next in carry) {
      carried[next] = allocator;
    }
  }
}

Set<SSA> _inputs(Operation op) => op is SpillNode
    ? {op.target}
    : op is ReloadNode
        ? {op.target}
        : op.readsFrom;
bool _same(Set<SSA> a, Set<SSA> b) => a.length == b.length && a.containsAll(b);
bool _immediate(SSA value) =>
    value is ImmediateSSA || value.name.startsWith('@');

class _BlockAllocator {
  final Map<int, RegType> types;
  final Map<Type, InstructionCreator> creators;
  final Set<SSA> stored;
  final Set<SSA> liveOut;
  final residents = <int, SSA>{};
  final result = <Operation>[];
  _BlockAllocator(this.types, this.creators, Set<SSA> liveIn, this.liveOut)
      : stored = {...liveIn};

  Set<int> registers(SSA value) {
    final type = types[value.type];
    if (type == null) {
      throw StateError('No register type for $value (${value.type})');
    }
    return {for (final group in type.regGroups) ...group.registers};
  }

  int? location(SSA value) {
    for (final entry in residents.entries) {
      if (entry.value == value) return entry.key;
    }
    return null;
  }

  void save(SSA value) {
    if (stored.contains(value) || _immediate(value)) return;
    final register = location(value);
    if (register == null) {
      throw StateError('No resident value to spill: $value');
    }
    result.add(SpillNode(AllocatedSSA.fromSSA(value, register)));
    stored.add(value);
  }

  void evict(int register, Set<SSA> needed) {
    final old = residents[register];
    if (old == null) return;
    if (needed.contains(old) &&
        residents.values.where((value) => value == old).length == 1) {
      save(old);
    }
    residents.remove(register);
  }

  void load(SSA value, int register, Set<SSA> needed) {
    if (!registers(value).contains(register)) {
      throw StateError('Register $register is incompatible with $value');
    }
    if (residents[register] == value) return;
    evict(register, needed);
    final source = location(value);
    if (source != null) {
      result.add(Assign(AllocatedSSA.fromSSA(value, register),
          AllocatedSSA.fromSSA(value, source)));
    } else {
      if (!stored.contains(value)) {
        throw StateError('No reaching definition for $value');
      }
      result.add(ReloadNode(AllocatedSSA.fromSSA(value, register)));
    }
    residents[register] = value;
  }

  bool canSwap(int first, int second) {
    final a = residents[first], b = residents[second];
    if (a == null || b == null) return false;
    return types[a.type]!.regGroups.any((group) =>
        group.registers.contains(first) &&
        group.registers.contains(second) &&
        types[b.type]!.regGroups.contains(group));
  }

  /// Place operands simultaneously. Acyclic copies run before resident cycles,
  /// so no move destroys the sole source of another pending operand.
  void place(Map<int, SSA> demanded, Set<SSA> needed) {
    final pending = {...demanded}
      ..removeWhere((register, value) => residents[register] == value);
    while (pending.isNotEmpty) {
      int? target;
      for (final register in pending.keys) {
        final old = residents[register];
        if (old == null ||
            !pending.containsValue(old) ||
            residents.entries
                .any((entry) => entry.key != register && entry.value == old)) {
          target = register;
          break;
        }
      }
      if (target != null) {
        load(pending.remove(target)!, target, needed);
        continue;
      }
      // Every pending destination now holds a sole source needed elsewhere.
      // Exchanging two members shortens a resident permutation cycle without
      // creating a spill slot. Never disturb an already satisfied destination.
      for (final entry in pending.entries) {
        final source = location(entry.value);
        if (source == null ||
            !pending.containsKey(source) ||
            !canSwap(entry.key, source)) {
          continue;
        }
        final old = residents[entry.key]!;
        result.add(SwapOp(AllocatedSSA.fromSSA(entry.value, source),
            AllocatedSSA.fromSSA(old, entry.key)));
        residents[entry.key] = entry.value;
        residents[source] = old;
        target = entry.key;
        break;
      }
      if (target == null) {
        // Overlapping register types need not provide a common swap group.
        // The canonical spill path safely breaks such a cycle as before.
        target = pending.keys.first;
        load(pending[target]!, target, needed);
      }
      pending.removeWhere((register, value) => residents[register] == value);
    }
  }

  Map<SSA, int> unconstrainedInputs(List<SSA> inputs) {
    final choices = <SSA, List<int>>{};
    for (final value in inputs.where((value) => !_immediate(value))) {
      final available = registers(value);
      choices[value] = [
        for (final register in available)
          if (residents[register] == value) register,
        for (final register in available)
          if (!residents.containsKey(register)) register,
        for (final register in available)
          if (residents.containsKey(register) && residents[register] != value)
            register,
      ];
    }
    final assigned = <SSA, int>{};
    final occupied = <int, SSA>{};
    bool assign(SSA value, Set<int> visited) {
      for (final register in choices[value]!) {
        if (!visited.add(register)) continue;
        final other = occupied[register];
        if (other == null || assign(other, visited)) {
          occupied[register] = value;
          assigned[value] = register;
          return true;
        }
      }
      return false;
    }

    // Overlapping types can require moving an earlier, less constrained
    // operand out of a scarce register. Duplicate operands share one placement.
    for (final value in choices.keys) {
      if (!assign(value, {})) {
        throw StateError('Too many simultaneous operands for register bank');
      }
    }
    return assigned;
  }

  List<Operation> allocate(List<Operation> code,
      {required Set<SSA> boundaryValues}) {
    // Install the entire incoming register set before processing any operation.
    // Seeding one parameter at a time could overwrite a later parameter.
    var executable = false;
    for (final op in code) {
      if (op is RegisterInput) {
        if (executable ||
            !registers(op.target).contains(op.register) ||
            residents.containsKey(op.register)) {
          throw StateError('Invalid incoming register definition');
        }
        residents[op.register] = op.target;
        stored.remove(op.target);
      } else {
        executable = true;
      }
    }
    final after = List<Set<SSA>>.generate(code.length, (_) => {});
    var needed = {...liveOut};
    final preferences = <SSA, Set<int>>{};
    final preferredOutputs = <int, Set<int>>{};
    for (var i = code.length - 1; i >= 0; i--) {
      final op = code[i];
      after[i] = {...needed};
      if (op.writesTo != null) {
        needed.remove(op.writesTo);
        preferredOutputs[i] = preferences[op.writesTo] ?? {};
      }
      needed.addAll(_inputs(op));
      final variants = creators[op.runtimeType]?.variantsFor(op);
      if (variants != null && variants.isNotEmpty) {
        for (var arg = 0; arg < op.operands.length; arg++) {
          preferences[op.operands[arg]] = {
            for (final variant in variants)
              if (arg < variant.arguments.length) variant.arguments[arg]
          };
        }
      }
    }
    for (var i = 0; i < code.length; i++) {
      final op = code[i];
      if (op is RegisterInput) continue;
      needed = {...after[i], ..._inputs(op)};
      residents.removeWhere((register, value) => !needed.contains(value));
      if (op is SpillNode) {
        save(op.target);
        continue;
      }
      if (op is ReloadNode) {
        if (location(op.target) == null) {
          final available = registers(op.target);
          final register = available.firstWhere(
              (r) => !residents.containsKey(r),
              orElse: () => available.first);
          load(op.target, register, needed);
        }
        continue;
      }
      if (op is Assign) {
        final available =
            registers(op.target).intersection(registers(op.source));
        if (available.isEmpty) {
          throw StateError(
              'Cross-bank assignment requires an explicit conversion');
        }
        final source = location(op.source);
        final register = source ??
            available.firstWhere((r) => !residents.containsKey(r),
                orElse: () => available.first);
        load(op.source, register, needed);
        if (after[i].contains(op.source) && op.source != op.target) {
          save(op.source);
        }
        residents[register] = op.target;
        stored.remove(op.target);
        result.add(Assign(AllocatedSSA.fromSSA(op.target, register),
            AllocatedSSA.fromSSA(op.source, register)));
        continue;
      }
      final inputs = op.operands;
      final creator = creators[op.runtimeType];
      final variants = creator?.variantsFor(op);
      Variant? chosen;
      var cost = 1 << 30;
      if (variants != null && variants.isNotEmpty) {
        for (final variant in variants) {
          if (variant.arguments.length != inputs.length) continue;
          if (op.writesTo != null &&
              !_immediate(op.writesTo!) &&
              (variant.result == null ||
                  !registers(op.writesTo!).contains(variant.result))) {
            continue;
          }
          final demanded = <int, SSA>{};
          var legal = true;
          var candidateCost = 0;
          for (var arg = 0; arg < inputs.length; arg++) {
            final value = inputs[arg], register = variant.arguments[arg];
            if (_immediate(value)) continue;
            if (!registers(value).contains(register) ||
                (demanded.containsKey(register) &&
                    demanded[register] != value)) {
              legal = false;
              break;
            }
            demanded[register] = value;
          }
          if (!legal) continue;
          for (final entry in demanded.entries) {
            if (residents[entry.key] == entry.value) continue;
            candidateCost++;
            // A reciprocal resident pair needs one swap rather than two
            // placements. Keep scoring local; longer cycles are resolved only
            // once, after selecting the variant, rather than simulating each.
            final source = location(entry.value);
            if (source != null &&
                source > entry.key &&
                demanded[source] == residents[entry.key] &&
                canSwap(entry.key, source)) {
              candidateCost--;
            }
          }
          // Loading an operand can evict this value before the instruction
          // writes its result. Do not hide that cost behind the demanded input.
          final incumbent = residents[variant.result];
          if (incumbent != null && after[i].contains(incumbent)) {
            candidateCost += stored.contains(incumbent) ? 1 : 2;
          }
          if (preferredOutputs[i]?.contains(variant.result) ?? false) {
            candidateCost--;
          }
          if (candidateCost < cost) {
            cost = candidateCost;
            chosen = variant;
          }
        }
        if (chosen == null) {
          throw StateError('No legal instruction variant for $op');
        }
      }
      final allocated = <SSA>[];
      final reserved = <int, SSA>{};
      final fallback = chosen == null ? unconstrainedInputs(inputs) : null;
      for (var arg = 0; arg < inputs.length; arg++) {
        final value = inputs[arg];
        if (_immediate(value)) {
          allocated.add(value);
          continue;
        }
        final register = chosen?.arguments[arg] ?? fallback![value]!;
        reserved[register] = value;
        allocated.add(AllocatedSSA.fromSSA(value, register));
      }
      place(reserved, needed);
      final output = op.writesTo;
      int? outputRegister;
      if (output != null && !_immediate(output)) {
        final available = registers(output);
        outputRegister = chosen?.result ??
            available.firstWhere((r) => !residents.containsKey(r),
                orElse: () => available.first);
      }
      final clobbers = creator?.clobberedRegistersFor(op) ?? <int>{};
      for (final register in {
        ...clobbers,
        if (outputRegister != null) outputRegister
      }) {
        evict(register, after[i]);
      }
      final newOutput = outputRegister == null
          ? output
          : AllocatedSSA.fromSSA(output!, outputRegister);
      result.add(op.copyWithOperands(writesTo: newOutput, operands: allocated));
      if (outputRegister != null) {
        residents[outputRegister] = output!;
        stored.remove(output);
      }
    }
    // Edge spill slots give every successor the same location for each live
    // value, including loop headers and critical edges. Stores precede branches.
    final terminal = result.isNotEmpty && result.last.isTerminator
        ? result.removeLast()
        : null;
    for (final value in boundaryValues) {
      save(value);
    }
    if (terminal != null) result.add(terminal);
    return result;
  }
}
