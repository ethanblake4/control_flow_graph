class Loop {
  final int header;
  final Set<int> blocks;
  final Set<(int, int)> exits;

  Loop(this.header, this.blocks, this.exits);
}
