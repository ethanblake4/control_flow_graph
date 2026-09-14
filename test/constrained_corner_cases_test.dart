import 'dart:math';
import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';
import 'constrained_allocation_test.dart' as machine;

void main() {
  test('deterministic arithmetic and clobber programs preserve live values',
      () {
    for (var seed = 0; seed < 40; seed++) {
      final random = Random(seed);
      final operations = <Operation>[];
      final expected = <String, int>{};
      void constant(String name, int n) {
        operations.add(machine.Op('constant', machine.value(name), [], n));
        expected[name] = n;
      }

      for (var i = 0; i < 6; i++) {
        constant('v$i', random.nextInt(20));
      }
      for (var i = 6; i < 30; i++) {
        final name = 'v$i';
        final left = 'v${random.nextInt(i)}';
        final right = random.nextInt(4) == 0 ? left : 'v${random.nextInt(i)}';
        final kind = random.nextInt(5);
        if (kind == 0) {
          operations.add(machine.Op('call', machine.value(name)));
          expected[name] = 7;
        } else if (kind == 1) {
          operations.add(Assign(machine.value(name), machine.value(left)));
          expected[name] = expected[left]!;
        } else {
          final subtract = kind == 2;
          operations.add(machine.Op(
              subtract ? 'sub' : 'add',
              machine.value(name),
              [machine.value(left), machine.value(right)]));
          expected[name] = subtract
              ? expected[left]! - expected[right]!
              : expected[left]! + expected[right]!;
        }
      }
      operations.add(machine.Op('return', null, [machine.value('v29')]));
      expect(machine.run(operations), expected['v29'], reason: 'seed $seed');
    }
  });

  test('loop swapping carried phi values preserves simultaneous copies', () {
    for (var trips = 1; trips <= 7; trips++) {
      SSA v(String name) => machine.value(name);
      final root = BasicBlock<Operation>([
        machine.Op('constant', v('x'), [], 2),
        machine.Op('constant', v('y'), [], 5),
        machine.Op('constant', v('i'), [], 0),
        machine.Op('constant', v('one'), [], 1),
        machine.Op('constant', v('limit'), [], trips),
      ]);
      final header = BasicBlock<Operation>([
        machine.Op('less', v('test'), [v('i'), v('limit')]),
        machine.Op('branch', ControlFlowGraph.branch, [v('test')])
      ]);
      final body = BasicBlock<Operation>([
        Assign(v('temp'), v('x')),
        Assign(v('x'), v('y')),
        Assign(v('y'), v('temp')),
        machine.Op('call', v('unused')),
        machine.Op('add', v('i'), [v('i'), v('one')])
      ]);
      final end = BasicBlock<Operation>([
        machine.Op('add', v('twice'), [v('x'), v('x')]),
        machine.Op('add', v('answer'), [v('twice'), v('y')]),
        machine.Op('return', null, [v('answer')])
      ]);
      final graph = ControlFlowGraph.builder()
          .root(root)
          .then(header)
          .split(body, end)
          .build();
      graph.link(body, header);
      expect(machine.execute(machine.compile(graph), root.id!),
          trips.isOdd ? 12 : 9,
          reason: 'trips $trips');
    }
  });

  test('critical join after clobber preserves unmodified branch values', () {
    for (final condition in [0, 1]) {
      SSA v(String name) => machine.value(name);
      final root = BasicBlock<Operation>([
        machine.Op('constant', v('x'), [], 4),
        machine.Op('constant', v('y'), [], 9),
        machine.Op('constant', v('condition'), [], condition),
        machine.Op('branch', ControlFlowGraph.branch, [v('condition')])
      ]);
      final taken = BasicBlock<Operation>([
        machine.Op('call', v('called')),
        machine.Op('add', v('x'), [v('x'), v('called')])
      ]);
      final end = BasicBlock<Operation>([
        machine.Op('sub', v('answer'), [v('x'), v('y')]),
        machine.Op('return', null, [v('answer')])
      ]);
      final graph =
          ControlFlowGraph.builder().root(root).then(taken).then(end).build();
      graph.link(root, end);
      expect(machine.execute(machine.compile(graph), root.id!),
          condition == 1 ? 2 : -5);
    }
  });
}
