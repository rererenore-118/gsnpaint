import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:html' as html;



void main() => runApp(const MaterialApp(home: GsnEditor()));

enum GsnNodeType { goal, strategy, solution, context, undeveloped}

class GsnNode {
  final int id;
  final GsnNodeType type;
  Offset position;
  double width;
  double height;
  String label;

  GsnNode({
    required this.id,
    required this.type,
    required this.position,
    this.width = 100,
    this.height = 60,
    String? label,
  }) : label = label ?? type.name.toUpperCase();
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

  void _editNodeLabel(GsnNode node) {
    final controller = TextEditingController(text: node.label);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ノード名を編集'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '新しい名前を入力'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                node.label = controller.text;
              });
              Navigator.of(context).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _exportToJson() {
    final jsonData = {
     'nodes': _nodes.map((n) => n.toJson()).toList(),
     'edges': _edges.map((e) => e.toJson()).toList(),
    };

    final jsonString = const JsonEncoder.withIndent('  ').convert(jsonData);
    debugPrint(jsonString); // 実運用ではファイル保存やシェア処理にする
    //ダウンロード処理
    final bytes = utf8.encode(jsonString);
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', 'gsn_data.json')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GSNエディタ"),
        actions: [
          IconButton(onPressed: () => _addNode(GsnNodeType.goal), icon: const Icon(Icons.square),  tooltip: 'Goalを追加',),
          IconButton(onPressed: () => _addNode(GsnNodeType.strategy),
                     icon: ParallelogramIcon(width: 24, height: 24, color: Colors.black),
                     tooltip: 'Strategyを追加',
                    ),
          IconButton(onPressed: () => _addNode(GsnNodeType.solution), icon: const Icon(Icons.circle), tooltip: 'Solutionを追加'),
          IconButton(onPressed: () => _addNode(GsnNodeType.context),
                     icon: const Icon(Icons.rectangle_rounded),
                     tooltip: 'Contextを追加',
                    ),
          IconButton(onPressed: () => _addNode(GsnNodeType.undeveloped),
                     icon: DiamondIcon(size: 28, color: Colors.black),
                     tooltip: 'Undevelopedノードを追加',
                    ),
        ],
      ),
      body: GestureDetector(
        child: Stack(
          children: [
            CustomPaint(
              size: Size.infinite,
              painter: GsnEdgePainter(_nodes, _edges),
            ),
            ..._nodes.map((node) {
              return Positioned(
                left: node.position.dx,
                top: node.position.dy,
                child: GestureDetector(
                  onTap: () => _startConnection(node.id),
                  onDoubleTap: () => _editNodeLabel(node),
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
      floatingActionButton: FloatingActionButton(
        onPressed: _exportToJson, // ← JSON出力関数
        tooltip: 'JSONとして保存',
        child: const Icon(Icons.save_alt), // 他にも Icons.download など可
      ),
    );
  }

  Widget _buildNodeWidget(GsnNode node) {
  final label = Text(
    node.label,
    textAlign: TextAlign.center,
    style: const TextStyle(fontWeight: FontWeight.bold),
  );

  final Widget shapeWidget = switch (node.type) {
    GsnNodeType.goal => Container(
        width: node.width,
        height: node.height,
        decoration: BoxDecoration(
          color: Colors.lightBlue,
          border: Border.all(color: Colors.black, width: 2),
        ),
        alignment: Alignment.center,
        child: label,
      ),
    GsnNodeType.strategy => CustomPaint(
        size: Size(node.width, node.height),
        painter: _ParallelogramPainter(Colors.orangeAccent),
        child: SizedBox(
          width: node.width,
          height: node.height,
          child: Center(child: label),
        ),
      ),
    GsnNodeType.solution => ClipOval(
        child: Container(
          width: node.width,
          height: node.height,
          color: Colors.greenAccent,
          alignment: Alignment.center,
          child: label,
        ),
      ),
    GsnNodeType.context => CustomPaint(
        size: Size(node.width, node.height),
        painter: _RoundedRectPainter(Colors.redAccent, 12),
        child: SizedBox(
          width: node.width,
          height: node.height,
          child: Center(child: label),
        ),
      ),
    GsnNodeType.undeveloped => CustomPaint(
        size: Size(node.width, node.height),
        painter: _DiamondPainter(Colors.purple),
        child: SizedBox(
          width: node.width,
          height: node.height,
          child: Center(child: label),
        ),
      ),
  };

  return Stack(
    children: [
      shapeWidget,
      // サイズ変更ハンドルは共通で配置
      Positioned(
        right: 0,
        bottom: 0,
        child: GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              node.width += details.delta.dx;
              node.height += details.delta.dy;
            });
          },
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const Icon(Icons.drag_handle, color: Colors.white, size: 10),
          ),
        ),
      ),
    ],
  );
}
}

class GsnEdgePainter extends CustomPainter {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;

  GsnEdgePainter(this.nodes, this.edges);

  @override
  void paint(Canvas canvas, Size size) {
    final linepaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;

      final arrowPaint = Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill;


    for (var edge in edges) {
      final fromNode = nodes.firstWhere((n) => n.id == edge.fromId);
      final toNode = nodes.firstWhere((n) => n.id == edge.toId);

      final start = fromNode.position + Offset(fromNode.width / 2, fromNode.height);
      final end = toNode.position + Offset(toNode.width / 2, 0);

      //線の描画
      canvas.drawLine(start, end, linepaint);

      //矢印の描画
      const double arrowSize = 10;
      final direction = (end - start).normalize();
      final perpendicular = Offset(-direction.dy, direction.dx);

      final arrowPoint1 = end - direction * arrowSize + perpendicular * (arrowSize / 2);
      final arrowPoint2 = end - direction * arrowSize - perpendicular * (arrowSize / 2);

      final path = Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(arrowPoint1.dx, arrowPoint1.dy)
        ..lineTo(arrowPoint2.dx, arrowPoint2.dy)
        ..close();

      canvas.drawPath(path, arrowPaint); 
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ParallelogramIcon extends StatelessWidget{
  final double width;
  final double height;
  final Color color;

  const ParallelogramIcon({
    this.width = 24,
    this.height = 24,
    this.color = Colors.black,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _ParallelogramPainter(color),
    );
  }
}

class _ParallelogramPainter extends CustomPainter{
  final Color color;
  _ParallelogramPainter(this.color);

  @override
  void paint(Canvas canvas, Size size){
    final paint = Paint()..color = color;

    final double offset = size.width * 0.2;
    final path = Path()
      ..moveTo(offset, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - offset, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class RoundedRectIcon extends StatelessWidget{
  final double width;
  final double height;
  final double borderRadius;
  final Color color;

  const RoundedRectIcon({
    this.width = 24,
    this.height = 24,
    this.color = Colors.black,
    this.borderRadius = 12,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _RoundedRectPainter(color, borderRadius),
    );
  }
}

class _RoundedRectPainter extends CustomPainter{
  final Color color;
  final double borderRadius;

  _RoundedRectPainter(this.color, this.borderRadius);

  @override
  void paint(Canvas canvas, Size size){
    final paint = Paint()..color = color;

    final double offset = size.width * 0.2;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0,0,size.width, size.height),
      Radius.circular(borderRadius),
    );

    canvas.drawRRect(rect, paint);
  }
  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class DiamondIcon extends StatelessWidget {
  final double size;
  final Color color;

  const DiamondIcon({
    this.size = 24,
    this.color = Colors.black,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _DiamondPainter(color),
    );
  }
}

class _DiamondPainter extends CustomPainter {

  final Color color;

  _DiamondPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;

    final path = Path()
      ..moveTo(size.width / 2, 0)                     // 上頂点
      ..lineTo(size.width, size.height / 2)           // 右頂点
      ..lineTo(size.width / 2, size.height)           // 下頂点
      ..lineTo(0, size.height / 2)                    // 左頂点
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DiamondPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

//拡張メソッド.normalize()
extension NormalizeOffset on Offset {
  Offset normalize() {
    final length = distance;
    return length == 0 ? this : this / length;
  }
}

//拡張　JSON出力用
extension GsnNodeJson on GsnNode {
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'label': label,
  };
}

extension GsnEdgeJson on GsnEdge {
  Map<String, dynamic> toJson() => {
    'from': fromId,
    'to': toId,
  };
}