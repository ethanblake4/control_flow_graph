[![License: BSD-3](https://img.shields.io/badge/license-BSD3-purple.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub](https://img.shields.io/github/last-commit/ethanblake4/control_flow_graph)](https://github.com/ethanblake4/control_flow_graph)

`control_flow_graph` provides a Dart library for creating and running various algorithms on
control flow graphs (CFGs), such as converting to SSA form, computing dominators, and
more.

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
}

final class Return extends Operation {
  final SSA value;

  Return(this.value);

  @override
  Set<SSA> get readsFrom => {value};
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

Currently, this library provides the following algorithms:
  - Compute immediate dominators
  - Compute dominator tree
  - Compute globals
  - Compute DJ-graph
  - Compute merge sets
  - Insert Phi nodes
  - Convert to semi-pruned SSA form
  - Remove Phi nodes from SSA form
  - Find variable version at a given block

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/ethanblake4/control_flow_graph/issues
