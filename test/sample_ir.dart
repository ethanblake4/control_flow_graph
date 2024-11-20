import 'package:control_flow_graph/control_flow_graph.dart';

final class LoadImmediate extends Operation {
  final SSA target;
  final int value;

  LoadImmediate(this.target, this.value);

  @override
  SSA? get writesTo => target;

  @override
  String toString() => '$target = imm $value';

  @override
  bool operator ==(Object other) =>
      other is LoadImmediate && target == other.target && value == other.value;

  @override
  int get hashCode => target.hashCode ^ value.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return LoadImmediate(writesTo ?? target, value);
  }

  @override
  bool get isRematerializable => true;
}

final class Add extends Operation {
  final SSA target;
  final SSA left;
  final SSA right;

  Add(this.target, this.left, this.right);

  @override
  Set<SSA> get readsFrom => {left, right};

  @override
  SSA? get writesTo => target;

  @override
  OpType get type => ArithmeticOp.add;

  @override
  String toString() => '$target = $left + $right';

  @override
  bool operator ==(Object other) =>
      other is Add &&
      target == other.target &&
      left == other.left &&
      right == other.right;

  @override
  int get hashCode => target.hashCode ^ left.hashCode ^ right.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return Add(writesTo ?? target, readsFrom?.firstOrNull ?? left,
        readsFrom?.lastOrNull ?? right);
  }
}

final class LessThan extends Operation {
  final SSA target;
  final SSA left;
  final SSA right;

  LessThan(this.target, this.left, this.right);

  @override
  Set<SSA> get readsFrom => {left, right};

  @override
  SSA? get writesTo => target;

  @override
  OpType get type => ComparisonOp.lessThan;

  @override
  String toString() => '$target = $left < $right';

  @override
  bool operator ==(Object other) =>
      other is LessThan &&
      target == other.target &&
      left == other.left &&
      right == other.right;

  @override
  int get hashCode => target.hashCode ^ left.hashCode ^ right.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return LessThan(writesTo ?? target, readsFrom?.firstOrNull ?? left,
        readsFrom?.lastOrNull ?? right);
  }
}

final class Return extends Operation {
  final SSA value;

  Return(this.value);

  @override
  Set<SSA> get readsFrom => {value};

  @override
  String toString() => 'return $value';

  @override
  bool operator ==(Object other) => other is Return && value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return Return(readsFrom?.single ?? value);
  }
}

final class INoop implements Instruction {}
