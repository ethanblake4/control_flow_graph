import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

import 'sample_instruction_set.dart';
import 'sample_ir.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds and fully allocates a single-block CFG containing:
///   a = imm 1
///   b = imm 2
///   c = [subtract]
///
/// where [subtract] is either `_Subtract(c, a, b)` (a - b) or
/// `_Subtract(c, b, a)` (b - a).
///
/// Returns the allocated register index for the variable named 'a'.
int _allocatedRegForA(_Subtract subtractOp) {
  final group = RegisterGroup({0, 1, 2, 3});
  final regType = RegType(0, 'gpr', {group});

  final a = SSA('a');
  final b = SSA('b');

  // A two-block CFG so the builder properly registers both blocks in the
  // graph (single-block builders don't add vertices until an edge is linked).
  final cfg = ControlFlowGraph.builder()
      .root(BasicBlock([
        LoadImmediate(a, 1),
        LoadImmediate(b, 2),
        subtractOp,
      ]))
      .then(BasicBlock([]))
      .build();

  cfg.registerRegType(-1, regType);
  cfg.registerRegType(0, regType);

  cfg.opCreators.addAll({
    LoadImmediate: Imm.creator,
    _Subtract: _Isub.creator,
  });

  cfg.insertPhiNodes();
  cfg.computeSemiPrunedSSA();
  cfg.spillReloadVariables({group: 4});
  cfg.removePhiNodes((l, r) => Assign(l, r));
  cfg.performRegisterAllocation();

  // Find the AllocatedSSA for 'a' in the block's code.
  for (final blockId in cfg.allLiveIn.keys) {
    for (final op in cfg[blockId]!.code) {
      // The LoadImmediate that defines 'a' will have writesTo.name == 'a'.
      final wt = op.writesTo;
      if (wt is AllocatedSSA && wt.name == 'a') {
        return wt.register;
      }
    }
  }

  fail('Could not find allocated register for variable "a"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Register preference pre-pass', () {
    test('a - b: a is allocated to the minuend register (r0)', () {
      final a = SSA('a');
      final b = SSA('b');
      final c = SSA('c');
      final reg = _allocatedRegForA(_Subtract(c, a, b));
      // _Isub has Variant(result: 0, arguments: [0, 1]):
      // left (a) → r0, right (b) → r1.
      expect(reg, equals(0),
          reason: 'a is the minuend so it should be preferred to r0');
    });

    test('b - a: a is allocated to the subtrahend register (r1)', () {
      final a = SSA('a');
      final b = SSA('b');
      final c = SSA('c');
      final reg = _allocatedRegForA(_Subtract(c, b, a));
      // _Isub has Variant(result: 0, arguments: [0, 1]):
      // left (b) → r0, right (a) → r1.
      expect(reg, equals(1),
          reason: 'a is the subtrahend so it should be preferred to r1');
    });

    test('allocated register for a differs between a-b and b-a', () {
      final a1 = SSA('a');
      final b1 = SSA('b');
      final c1 = SSA('c');
      final regAB = _allocatedRegForA(_Subtract(c1, a1, b1));

      final a2 = SSA('a');
      final b2 = SSA('b');
      final c2 = SSA('c');
      final regBA = _allocatedRegForA(_Subtract(c2, b2, a2));

      expect(regAB, isNot(equals(regBA)),
          reason:
              'a should land in different registers depending on whether it '
              'is the minuend or the subtrahend');
    });
  });
}

// Keep this regression independent of experimental sample instruction changes.
final class _Subtract extends Operation {
  final SSA target;
  final SSA left;
  final SSA right;
  _Subtract(this.target, this.left, this.right);
  @override
  SSA get writesTo => target;
  @override
  Set<SSA> get readsFrom => {left, right};
  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) => _Subtract(
      writesTo ?? target, readsFrom?.first ?? left, readsFrom?.last ?? right);
}

final class _Isub extends Instruction {
  static final creator = Creator<_Subtract, ContextData>(
    variants: {
      Variant(result: 0, arguments: [0, 1])
    },
    create: (op, context) => _Isub(),
  );
}
