import 'package:control_flow_graph/control_flow_graph.dart';

final class LoadImmediate extends Operation {
  final SSA target;
  final int value;

  LoadImmediate(this.target, this.value);

  @override
  Set<SSA> get writesTo => {target};

  @override
  String toString() => '$target = imm $value';

  @override
  bool operator ==(Object other) =>
      other is LoadImmediate && target == other.target && value == other.value;

  @override
  int get hashCode => target.hashCode ^ value.hashCode;
}

final class Add extends Operation {
  final SSA target;
  final SSA left;
  final SSA right;

  Add(this.target, this.left, this.right);

  @override
  Set<SSA> get readsFrom => {left, right};

  @override
  Set<SSA> get writesTo => {target};

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
}

final class Assign extends Operation {
  final SSA target;
  final SSA source;

  Assign(this.target, this.source);

  @override
  Set<SSA> get readsFrom => {source};

  @override
  Set<SSA> get writesTo => {target};

  @override
  String toString() => '$target = $source';

  @override
  bool operator ==(Object other) =>
      other is Assign && target == other.target && source == other.source;

  @override
  int get hashCode => target.hashCode ^ source.hashCode;
}

final class LessThan extends Operation {
  final SSA target;
  final SSA left;
  final SSA right;

  LessThan(this.target, this.left, this.right);

  @override
  Set<SSA> get readsFrom => {left, right};

  @override
  Set<SSA> get writesTo => {target};

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
}
