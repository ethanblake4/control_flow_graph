import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

void main() {
  test('renaming keeps repeated positions and shares their replacement', () {
    final x = SSA('x');
    final y = SSA('y');
    final renamedX = SSA('x', version: 1);
    final renamedY = SSA('y', version: 2);
    final result = renameOperands([y, x, y], {y, x}, {renamedY, renamedX});
    expect(result, [renamedY, renamedX, renamedY]);
    expect(result.first, same(result.last));
  });

  test('renaming rejects a missing replacement', () {
    final x = SSA('x');
    final y = SSA('y');
    expect(() => renameOperands([x, y], {x, y}, {SSA('x', version: 1)}),
        throwsArgumentError);
  });
}
