## Unreleased

- Own SSA and frontend graph validation, including predecessor-specific phi checks.
- Add ordered operand renaming, SSA equality constraints, and copy-chain lookup.
- Allow caller-specific dead-result removal and refresh metadata before DCE.
- Add block layout with label preservation and target-driven branch relaxation.
- Rename SSA values through the dominator tree and remove unused phi cycles.
- Keep copy propagation's instructions and def-use metadata consistent.

## 1.3.0
- Added working register allocation algorithm
- Add machine code generation
- Fixed spill algorithm
- Added ImmediateSSA to represent immediate values in IR

## 1.2.0
- Added new utilities to builder class
- Improved SSA renaming algorithm
- Live-in computation now correctly handles phi nodes
- Fix bug allowing DCE optimization to remove root block
- Added ability to define loop structures
- Added ability to define register groups and mark
  supported register types per variable
- Added live-in set and next-use distance computations
- Added register pressure computation
- Added register spill/reload insertion
- Added instruction builders to specify how IR will be 
  converted to machine code

## 1.1.0

- Improved SSA renaming algorithm.
- Added liveness computations
- Added copy propagation, unused defines elimination, and dead block 
  elimination optimizations.

## 1.0.0

- Initial version.
