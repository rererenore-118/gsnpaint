import 'package:flutter/material.dart';

void main() => runApp(const GsnEditorApp());

class GsnEditorApp extends StatelessWidget {
  const GsnEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: GsnEditorScreen(),
    );
  }
}

enum GsnNodeType { goal, strategy, solution }

class GsnNode {
  final GsnNodeType type;
  final String label;
  final Offset position;

  GsnNode({required this.type, required this.label, required this.position});
}

class GsnEditorScreen extends StatefulWidget {
  const GsnEditorScreen({super.key});

  @override
  State<GsnEditorScreen> createState() => _GsnEditorScreenState();
}

class _GsnEditorScreenState extends State<GsnEditorScreen> {
  final List<GsnNode> _nodes = [];

  double _nextY = 50;

  void _addNode(GsnNodeType type) {
    String label = switch (type) {
      GsnNodeType.goal => 'Goal',
      GsnNodeType.strategy => 'Strategy',
      GsnNodeType.solution => 'Solution',
    };

    final node = GsnNode(
      type: type,
      label: label,
      position: Offset(150, _nextY),
    );

    setState(() {
      _nodes.add(node);
      _nextY += 100; // 次のノードのy座標
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GSNノードエディタ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bubble_chart),
            tooltip: 'Goal追加',
            onPressed: () => _addNode(GsnNodeType.goal),
          ),
          IconButton(
            icon: const Icon(Icons.account_tree),
            tooltip: 'Strategy追加',
            onPressed: () => _addNode(GsnNodeType.strategy),
          ),
          IconButton(
            icon: const Icon(Icons.check_circle),
            tooltip: 'Solution追加',
            onPressed: () => _addNode(GsnNodeType.solution),
          ),
        ],
      ),
      body: CustomPaint(
        painter: GsnPainter(nodes: _nodes),
        child: Container(),
      ),
    );
  }
}

class GsnPainter extends CustomPainter {
  final List<GsnNode> nodes;

  GsnPainter({required this.nodes});

  @override
  void paint(Canvas canvas, Size size) {
    const nodeSize = Size(120, 60);

    final Paint rectPaint = Paint()
      ..color = Colors.yellow.shade100
      ..style = PaintingStyle.fill;

    final Paint borderPaint = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final Paint arrowPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;

    // ノード描画
    for (var node in nodes) {
      final rect = Rect.fromLTWH(node.position.dx, node.position.dy, nodeSize.width, nodeSize.height);
      canvas.drawRect(rect, rectPaint);
      canvas.drawRect(rect, borderPaint);
      _drawLabel(canvas, node.label, node.position, nodeSize.width);
    }

    // 矢印：単純に前のノードと繋ぐ（上下接続）
    for (int i = 0; i < nodes.length - 1; i++) {
      final from = nodes[i].position.translate(nodeSize.width / 2, nodeSize.height);
      final to = nodes[i + 1].position.translate(nodeSize.width / 2, 0);
      canvas.drawLine(from, to, arrowPaint);
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset offset, double width) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(color: Colors.black, fontSize: 14),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(minWidth: width, maxWidth: width);
    textPainter.paint(canvas, offset.translate(0, 20));
  }

  @override
  bool shouldRepaint(covariant GsnPainter oldDelegate) {
    return oldDelegate.nodes != nodes;
  }
}
