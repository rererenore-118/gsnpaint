import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: GsnEditor()));

enum GsnNodeType { goal, strategy, solution }

class GsnNode {
  final int id;
  final GsnNodeType type;
  Offset position;
  GsnNode({required this.id, required this.type, required this.position});
}

class GsnEdge {
  final int fromId;
  final int toId;
  GsnEdge(this.fromId, this.toId);
}

class GsnEditor extends StatefulWidget {
  const GsnEditor({super.key});

  @override
  State<GsnEditor> createState() => _GsnEditorState();
}

class _GsnEditorState extends State<GsnEditor> {
  final List<GsnNode> _nodes = [];
  final List<GsnEdge> _edges = [];
  int _nodeCounter = 0;
  int? _connectingNodeId;

  void _addNode(GsnNodeType type) {
    setState(() {
      _nodes.add(GsnNode(
        id: _nodeCounter++,
        type: type,
        position: const Offset(100, 100),
      ));
    });
  }

  void _startConnection(int nodeId) {
    setState(() {
      if (_connectingNodeId == null) {
        _connectingNodeId = nodeId;
      } else if (_connectingNodeId != nodeId) {
        _edges.add(GsnEdge(_connectingNodeId!, nodeId));
        _connectingNodeId = null;
      }
    });
  }

  void _updateNodePosition(int nodeId, Offset newPosition) {
    setState(() {
      final node = _nodes.firstWhere((n) => n.id == nodeId);
      node.position = newPosition;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GSNエディタ"),
        actions: [
          IconButton(onPressed: () => _addNode(GsnNodeType.goal), icon: const Icon(Icons.flag)),
          IconButton(onPressed: () => _addNode(GsnNodeType.strategy), icon: const Icon(Icons.extension)),
          IconButton(onPressed: () => _addNode(GsnNodeType.solution), icon: const Icon(Icons.check_circle)),
        ],
      ),
      body: GestureDetector(
        child: Stack(
          children: [
            // 線の描画（カスタムペイント）
            CustomPaint(
              size: Size.infinite,
              painter: GsnEdgePainter(_nodes, _edges),
            ),
            // ノード描画とイベント処理
            ..._nodes.map((node) {
              return Positioned(
                left: node.position.dx,
                top: node.position.dy,
                child: GestureDetector(
                  onTap: () => _startConnection(node.id),
                  onPanUpdate: (details) {
                    _updateNodePosition(node.id, node.position + details.delta);
                  },
                  child: _buildNodeWidget(node),
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeWidget(GsnNode node) {
    final color = switch (node.type) {
      GsnNodeType.goal => Colors.lightBlue,
      GsnNodeType.strategy => Colors.orangeAccent,
      GsnNodeType.solution => Colors.greenAccent,
    };

    return Container(
      width: 100,
      height: 60,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: Colors.black, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        node.type.name.toUpperCase(),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }
}

class GsnEdgePainter extends CustomPainter {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;

  GsnEdgePainter(this.nodes, this.edges);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;

    for (var edge in edges) {
      final from = nodes.firstWhere((n) => n.id == edge.fromId).position;
      final to = nodes.firstWhere((n) => n.id == edge.toId).position;

      final start = from + const Offset(50, 60); // ノード中央
      final end = to + const Offset(50, 0);
      canvas.drawLine(start, end, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
