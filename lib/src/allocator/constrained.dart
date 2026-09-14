import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:more/more.dart';
import 'package:control_flow_graph/src/operation.dart';
import 'package:control_flow_graph/src/types.dart';

/// Allocates constrained instructions, retaining block-local register contents
/// and backing evicted live values with canonical SSA spill slots.
void allocateConstrained(CFG graph, int root, Map<int, BasicBlock> blocks,
    Map<int, RegType> types, Map<Type, InstructionCreator> creators) {
  final order = graph.depthFirstPostOrder(root).toList().reversed.toList();
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
    final next = successors.length == 1 ? successors.single : null;
    final carry = next != null &&
        graph.predecessorsOf(next).length == 1 &&
        order.indexOf(next) > order.indexOf(id);
    final code = allocator.allocate(blocks[id]!.code, spillBoundary: !carry);
    blocks[id]!.code
      ..clear()
      ..addAll(code);
    if (carry) carried[next] = allocator;
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

  List<Operation> allocate(List<Operation> code, {bool spillBoundary = true}) {
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
            if (residents[register] != value) candidateCost++;
          }
          if (!legal) continue;
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
      for (var arg = 0; arg < inputs.length; arg++) {
        final value = inputs[arg];
        if (_immediate(value)) {
          allocated.add(value);
          continue;
        }
        final available = registers(value);
        final register = chosen?.arguments[arg] ??
            available.firstWhere(
                (r) =>
                    residents[r] == value &&
                    (!reserved.containsKey(r) || reserved[r] == value),
                orElse: () => available.firstWhere(
                    (r) => !reserved.containsKey(r),
                    orElse: () => throw StateError(
                        'Too many simultaneous operands for register bank')));
        // Before an earlier argument overwrites a later argument, eviction
        // saves its value. Ordered operands may load one SSA into two registers.
        load(value, register, needed);
        reserved[register] = value;
        allocated.add(AllocatedSSA.fromSSA(value, register));
      }
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
    if (spillBoundary) {
      for (final value in liveOut) {
        save(value);
      }
    }
    if (terminal != null) result.add(terminal);
    return result;
  }
}
