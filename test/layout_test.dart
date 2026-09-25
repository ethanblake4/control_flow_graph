import 'package:control_flow_graph/control_flow_graph.dart';
import 'package:test/test.dart';

class TestInstruction extends Instruction {
  TestInstruction(this.kind, {this.target, this.size = 1});

  final String kind;
  final int? target;
  final int size;
}

void main() {
  test('layout forwards branches while preserving alias labels', () {
    final blocks = layoutBlocks<TestInstruction>(
      {
        0: [
          TestInstruction('branch', target: 1),
          TestInstruction('jump', target: 2),
        ],
        1: [TestInstruction('jump', target: 5)],
        5: [TestInstruction('jump', target: 3)],
        2: [
          TestInstruction('work'),
          TestInstruction('jump', target: 4),
        ],
        3: [
          TestInstruction('work'),
          TestInstruction('jump', target: 4),
        ],
        4: [TestInstruction('return')],
      },
      jumpTarget: (instruction) =>
          instruction.kind == 'jump' ? instruction.target : null,
      branchTarget: (instruction) =>
          instruction.kind == 'branch' ? instruction.target : null,
      retargetBranch: (instruction, target) =>
          TestInstruction(instruction.kind, target: target),
    );

    expect(blocks.keys.toList(), [0, 2, 4, 1, 5, 3]);
    expect(blocks[0]!.first.target, 3);
    expect(blocks[0]!.length, 1);
    expect(blocks[2]!.length, 1);
    expect(blocks[1], isEmpty);
    expect(blocks[5], isEmpty);
    final offsets = relaxBranches<TestInstruction>(
      blocks,
      length: (instruction) => instruction.size,
      branchTarget: (_) => null,
      widen: (instruction, distance) => null,
    );
    expect(offsets[1], offsets[3]);
    expect(offsets[5], offsets[3]);
  });

  test('branch relaxation repeats when widening pushes another branch out', () {
    final blocks = <int, List<TestInstruction>>{
      0: [TestInstruction('a', target: 3, size: 2)],
      1: [TestInstruction('b', target: 4, size: 2)],
      2: [TestInstruction('work')],
      3: [TestInstruction('work')],
      4: [TestInstruction('return')],
    };
    final offsets = relaxBranches<TestInstruction>(
      blocks,
      length: (instruction) => instruction.size,
      branchTarget: (instruction) =>
          instruction.size == 2 ? instruction.target : null,
      widen: (instruction, distance) =>
          distance > (instruction.kind == 'a' ? 3 : 1)
              ? TestInstruction(instruction.kind,
                  target: instruction.target, size: 4)
              : null,
    );

    expect(blocks[0]!.single.size, 4);
    expect(blocks[1]!.single.size, 4);
    expect(offsets, {0: 0, 1: 4, 2: 8, 3: 9, 4: 10});
  });

  test('jump-only cycle keeps an executable loop', () {
    final blocks = layoutBlocks<TestInstruction>(
      {
        0: [TestInstruction('jump', target: 1)],
        1: [TestInstruction('jump', target: 0)],
      },
      jumpTarget: (instruction) => instruction.target,
      branchTarget: (instruction) => null,
      retargetBranch: (instruction, target) =>
          TestInstruction(instruction.kind, target: target),
    );

    expect(blocks.keys.toList(), [1, 0]);
    expect(blocks[1], isEmpty);
    expect(blocks[0]!.single.target, 0);
  });

  test('branch relaxation rejects replacement without longer encoding', () {
    expect(
      () => relaxBranches<TestInstruction>(
        {
          0: [TestInstruction('branch', target: 1)],
          1: [TestInstruction('return')],
        },
        length: (instruction) => instruction.size,
        branchTarget: (instruction) => instruction.target,
        widen: (instruction, _) =>
            TestInstruction(instruction.kind, target: instruction.target),
      ),
      throwsStateError,
    );
  });
}
