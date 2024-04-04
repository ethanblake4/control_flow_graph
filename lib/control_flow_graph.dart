/// Library for creating and manipulating control flow graphs and SSA form.
library control_flow_graph;

export 'src/basic_block.dart';
export 'src/cfg.dart' show ControlFlowGraph;
export 'src/dj_graph.dart' show jEdge, dEdge;
export 'src/operation.dart';
export 'src/ssa.dart' show SSA;
