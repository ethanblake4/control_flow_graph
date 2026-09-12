/// Library for creating and manipulating control flow graphs and SSA form.
library control_flow_graph;

export 'src/assembler.dart'
    show AssemblerConfig, SpillCallback, ReloadCallback, MoveCallback, SwapCallback;
export 'src/basic_block.dart';
export 'src/builder.dart';
export 'src/cfg.dart' show ControlFlowGraph;
export 'src/dj_graph.dart' show jEdge, dEdge;
export 'src/operation.dart' hide SpillNode, ReloadNode;
export 'src/ssa.dart' show SSA, AllocatedSSA, ImmediateSSA;
export 'src/instructions/context.dart' show AssembleContext;
export 'src/instructions/instruction.dart';

export 'src/types.dart' show RegType, RegisterGroup;
