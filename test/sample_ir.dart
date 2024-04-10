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
  Operation copyWith({SSA? writesTo}) {
    return LoadImmediate(writesTo ?? target, value);
  }
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
  Operation copyWith({SSA? writesTo}) {
    return Add(writesTo ?? target, left, right);
  }
}

final class Assign extends Operation {
  final SSA target;
  final SSA source;

  Assign(this.target, this.source);

  @override
  Set<SSA> get readsFrom => {source};

  @override
  SSA? get writesTo => target;

  @override
  OpType get type => AssignmentOp.assign;

  @override
  String toString() => '$target = $source';

  @override
  bool operator ==(Object other) =>
      other is Assign && target == other.target && source == other.source;

  @override
  int get hashCode => target.hashCode ^ source.hashCode;

  @override
  Operation copyWith({SSA? writesTo}) {
    return Assign(writesTo ?? target, source);
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
  Operation copyWith({SSA? writesTo}) {
    return LessThan(writesTo ?? target, left, right);
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
  Operation copyWith({SSA? writesTo}) {
    return this;
  }
}
