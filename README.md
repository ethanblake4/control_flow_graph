[![License: BSD-3](https://img.shields.io/badge/license-BSD3-purple.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub](https://img.shields.io/github/last-commit/ethanblake4/control_flow_graph)](https://github.com/ethanblake4/control_flow_graph)

`control_flow_graph` provides a Dart library for building compilers
based on control flow graphs and SSA form. It includes a variety of 
algorithms for analyzing and transforming
control flow graphs (CFGs), such as converting to SSA form, computing dominators, 
register spilling, and more, as well as a register allocator
and machine code generator.
This is useful for writing compilers, interpreters, and 
static analysis tools.

## Shared compiler passes

The package owns graph and SSA invariants. A frontend supplies its operations,
language rules, and target instruction encodings.

- Use `Assign` for value copies and `renameOperands` when adapting ordered
  operands to `Operation.copyWith`. The latter preserves repeated arguments.
- Use `graph.clone()` to copy a graph before transforming it. A clone with
  `refresh: false` has no usable SSA metadata until `refreshSSA()` runs.
- `validateControlFlowGraph` checks definitions, terminator placement, and
  edges. Its callbacks describe the frontend's branches and exits; the
  frontend still validates its exception-handler declarations.
- `validateSSA` checks unique definitions, dominance, and each phi input's
  association with its predecessor. Run it before leaving SSA form.
- `SSAValueConstraints<T>` propagates caller-defined facts through equality
  constraints. The compiler supplies representation or type rules.
- `SSADefinitions` takes a snapshot of current definitions and can follow
  `Assign` chains without depending on cached graph metadata.
- `graph.removeUnusedDefines()` refreshes SSA metadata and removes unused
  pure definitions. A `canRemove` callback replaces the default purity policy
  when a compiler has additional proof that an operation can be discarded.

For machine code, set `AssemblerConfig.emitFallthroughJumps` when passing
assembled blocks to `layoutBlocks`. This keeps control-flow edges explicit
until the final layout chooses fallthroughs. `layoutBlocks` forwards jump
chains and preserves block IDs as labels, including exception destinations.
`relaxBranches` computes label offsets and widens branches until the layout
stabilizes. The target supplies instruction lengths and widening rules, then
uses the returned offsets to encode instructions and patch its own tables.

## Getting started

To use `control_flow_graph`, you'll first have to create some SSA-based operations.
Each operation is a subclass of `Operation` and must describe the variables it 
writes to and reads from. For example, here's three example operations that
load an integer value, perform a less-than comparison, and return a value:

```dart
final class LoadImmediate extends Operation {
  final SSA target;
  final int value;

  LoadImmediate(this.target, this.value);

  @override
  Set<SSA> get writesTo => {target};

  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return LoadImmediate(writesTo ?? target, value);
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
  Set<SSA> get writesTo => {target};

  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return LessThan(writesTo ?? target, readsFrom?.firstOrNull ?? left, readsFrom?.lastOrNull ?? right);
  }
}

final class Return extends Operation {
  final SSA value;

  Return(this.value);

  @override
  Set<SSA> get readsFrom => {value};

  Operation copyWith({SSA? writesTo, Set<SSA>? readsFrom}) {
    return Return(readsFrom?.single ?? value);
  }
}
```

Next, you'll need to create a `ControlFlowGraph` and add some basic blocks to it.
A basic block is a list of operations that are executed in sequence. Only the last
operation in a basic block can perform a branch. `control_flow_graph` includes
a helpful builder method to make creating a CFG easier:

```dart
final cfg = ControlFlowGraph.builder()
  .root(BasicBlock([
    LoadImmediate(SSA('a'), 1),
    LoadImmediate(SSA('b'), 2),
    LessThan(ControlFlowGraph.branch, SSA('a'), SSA('b')),
  ]))
  .split(
    BasicBlock([LoadImmediate(SSA('z'), 3)]),
    BasicBlock([LoadImmediate(SSA('z'), 4)]),
  )
  .merge(BasicBlock([
    Return(SSA('z'))
  ]))
  .build();
```

Now that you have a CFG, you can run various algorithms on it:

```dart
// Compute dominator tree
final dominatorTree = cfg.dominatorTree;

// Get global variables
final globals = cfg.globals;

// Insert Phi nodes
cfg.insertPhiNodes();

// Convert to SSA form
cfg.computeSemiPrunedSSA();
```

## Accessing the graph

Basic blocks in the graph can be accessed via ID or label simply by indexing
into the graph:

```dart
final cfg = ControlFlowGraph.builder()
  .root(BasicBlock([
    LoadImmediate(SSA('a'), 1),
    LoadImmediate(SSA('b'), 2),
    LessThan(ControlFlowGraph.branch, SSA('a'), SSA('b')),
  ], label: 'rootBlock')).build();

final block = cfg[0]; // Access block by ID

final block = cfg['rootBlock']; // Access block by label
```

You can also access the underlying directed graph:

```dart
final graph = cfg.graph;
```

If you modify the graph directly, you'll need to call `cfg.invalidate()` to
signal that the graph has changed.

## Available algorithms

This library provides the following algorithms:
  - Compute immediate dominators
  - Compute dominator tree
  - Compute globals
  - Compute DJ-graph
  - Compute merge sets (per-basic block DF+ sets)
  - Insert Phi nodes
  - Convert to semi-pruned SSA form
  - Query liveness information (in & out)
  - Compute live-in sets
  - Compute global next-use distances
  - Find variable version at a given block
  - Copy propagation
  - Unused defines elimination
  - Dead block elimination
  - Compute register pressure
  - Spill and reload variables to/from memory
  - Remove Phi nodes from SSA form
  - Register allocation
  - Convert to machine code

## Note on SSA algorithm

This library implements a novel SSA renaming algorithm. While it is much faster than
other approaches, it requires that variables be defined in or above the scope they are
used. For example, the following PHP code will not work:

```php
$x = 1;
if ($x < 2) {
  $y = 3;
} else {
  $y = 4;
}
echo $y;
```

To make this code computable, you would have to hoist the declaration of `$y` above
the if-else block. Many languages like Dart, C, and Java already enforce this
restriction, so it should not be relevant in practice when used with them.

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/ethanblake4/control_flow_graph/issues

## Citations

- [SSA-based Compiler Design. Rastello, F. and Bouchez, F.](https://link.springer.com/book/10.1007/978-3-030-80515-9)
- [A practical and fast iterative algorithm for ϕ-function computation using DJ graphs. Das, D., B. Dupont De Dinechin and R. Upadrasta](https://dl.acm.org/doi/10.1145/1065887.1065890)
- [Efficient liveness computation using merge sets and DJ-graphs. Das, D. and Ramakrishna, U.](https://dl.acm.org/doi/10.1145/1065887.1065891)
- [SSA-based Register Allocation, Universität des Saarlandes Compiler Design Lab](https://compilers.cs.uni-saarland.de/projects/ssara/)
- [Preference-guided Register Assignment, Braun, M., Mallon, C. and Hack, S.](https://link.springer.com/chapter/10.1007/978-3-642-11970-5_12)
- [The Go Programming Language, The Go Authors](https://github.com/golang/go)
