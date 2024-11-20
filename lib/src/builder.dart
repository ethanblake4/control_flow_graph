import 'package:control_flow_graph/control_flow_graph.dart';

class BasicBlockBuilder {
  final ControlFlowGraph _cfg;
  final List<BasicBlock> _blocks;
  final BasicBlockBuilder? _parent;
  final BasicBlockBuilder? _groupStart;

  BasicBlockBuilder(this._cfg, this._blocks, this._parent, [this._groupStart]);

  BasicBlockBuilder float(BasicBlock block) {
    _cfg.append(block);
    return this;
  }

  BasicBlockBuilder merge(BasicBlock block) {
    _cfg.linkAll(_blocks, [block]);
    return BasicBlockBuilder(_cfg, [block], this, _groupStart);
  }

  BasicBlockBuilder then(BasicBlock block) => merge(block);

  BasicBlockBuilder split(BasicBlock b1, BasicBlock b2,
      [BasicBlock? b3,
      BasicBlock? b4,
      BasicBlock? b5,
      BasicBlock? b6,
      BasicBlock? b7,
      BasicBlock? b8]) {
    assert(_blocks.length == 1, 'Only one block can be split');
    final blocks = [
      b1,
      b2,
      if (b3 != null) b3,
      if (b4 != null) b4,
      if (b5 != null) b5,
      if (b6 != null) b6,
      if (b7 != null) b7,
      if (b8 != null) b8,
    ];
    _cfg.linkAll(_blocks, blocks);
    return BasicBlockBuilder(_cfg, blocks, this, _groupStart);
  }

  BasicBlockBuilder splitMerge(BasicBlock split, BasicBlock merge) {
    assert(_blocks.length == 1, 'Only one block can be split');
    _cfg.linkAll(_blocks, [split, merge]);
    _cfg.link(split, merge);
    return BasicBlockBuilder(_cfg, [merge], this, _groupStart);
  }

  BasicBlockBuilder block(int index) {
    return BasicBlockBuilder(_cfg, [_blocks[index]], this, this);
  }

  BasicBlockBuilder commit() {
    assert(_groupStart != null, 'Cannot commit outside group');
    return _groupStart!;
  }

  void link(BasicBlock b1, BasicBlock b2) {
    _cfg.link(b1, b2);
  }

  BasicBlockBuilder get _root => _parent == null ? this : _parent._root;
  BasicBlockBuilder get root => _root;

  ControlFlowGraph build() {
    _cfg.root = _root._blocks.first;
    return _cfg;
  }

  BasicBlockBuilder operator [](int index) => block(index);
}
