import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:html' as html;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MaterialApp(home: GsnEditor()));

enum GsnNodeType { goal, strategy, evidence, assumption, context, undeveloped }

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

  factory GsnNode.fromJson(Map<String, dynamic> json) {
    return GsnNode(
      id: json['id'],
      type: GsnNodeType.values.firstWhere(
        (e) => _gsnTypeName(e) == json['gsn_type'],
        orElse: () => GsnNodeType.goal,
      ),
      position: Offset(json['position_x'], json['position_y']),
      width: json['width'] ?? 100,
      height: json['height'] ?? 60,
      label: json['description'],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'gsn_type': _gsnTypeName(type),
        'description': label,
        'position_x': position.dx,
        'position_y': position.dy,
        'width': width,
        'height': height,
      };

  static String _gsnTypeName(GsnNodeType t) {
    switch (t) {
      case GsnNodeType.goal:
        return 'Goal';
      case GsnNodeType.strategy:
        return 'Strategy';
      case GsnNodeType.evidence:
        return 'Evidence';
      case GsnNodeType.assumption:
        return 'Assumption';
      case GsnNodeType.context:
        return 'Context';
      case GsnNodeType.undeveloped:
        return 'Undeveloped';
    }
  }
}

class GsnEdge {
  final int fromId;
  final int toId;
  GsnEdge(this.fromId, this.toId);

  factory GsnEdge.fromJson(Map<String, dynamic> json) {
    return GsnEdge(json['from'], json['to']);
  }

  Map<String, dynamic> toJson() => {'from': fromId, 'to': toId};
}

class GsnEditor extends StatefulWidget {
  const GsnEditor({super.key});

  @override
  State<GsnEditor> createState() => _GsnEditorState();
}

class _GsnEditorState extends State<GsnEditor> {
  final TransformationController _tc = TransformationController();
  final Size _worldSize = const Size(4000, 4000);

  final List<GsnNode> _nodes = [];
  final List<GsnEdge> _edges = [];
  int _nodeCounter = 0;
  bool _deleteMode = false;
  int? _connecting;

  static const double _minW = 60;
  static const double _minH = 40;
  static const double _maxW = 800;
  static const double _maxH = 600;

  @override
  void initState() {
    super.initState();
    _loadFromLocalStorage();
  }

  Future<void> _saveToLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final data = {
      'nodes': _nodes.map((n) => n.toJson()).toList(),
      'edges': _edges.map((e) => e.toJson()).toList(),
      'nodeCounter': _nodeCounter,
    };
    final jsonString = jsonEncode(data);
    await prefs.setString('gsn_editor_data', jsonString);
  }

  Future<void> _loadFromLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString('gsn_editor_data');
    if (jsonString == null) return;

    try {
      final data = jsonDecode(jsonString);
      setState(() {
        _nodes.clear();
        _edges.clear();
        _nodes.addAll(
            (data['nodes'] as List).map((n) => GsnNode.fromJson(n)));
        _edges.addAll(
            (data['edges'] as List).map((e) => GsnEdge.fromJson(e)));
        _nodeCounter = data['nodeCounter'] ?? 0;
      });
    } catch (e) {
      print("データの読み込みに失敗しました: $e");
    }
  }

  // ★ 修正: ドロップされた位置(Offset)を引数で受け取るように変更
  void _addNode(GsnNodeType type, Offset position) {
    setState(() {
      _nodes.add(GsnNode(
        id: _nodeCounter++,
        type: type,
        position: position,
      ));
    });
    _saveToLocalStorage();
  }

  void _toggleDeleteMode() {
    setState(() => _deleteMode = !_deleteMode);
  }

  void _handleTapNode(GsnNode node) {
    if (_deleteMode) {
      _confirmDeleteNode(node);
    } else {
      if (_connecting == null) {
        setState(() => _connecting = node.id);
      } else if (_connecting != node.id) {
        setState(() {
          _edges.add(GsnEdge(_connecting!, node.id));
          _connecting = null;
        });
        _saveToLocalStorage();
      } else {
        setState(() => _connecting = null);
      }
    }
  }

  void _confirmDeleteNode(GsnNode node) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ノード削除'),
        content: Text('「${node.label}」を削除しますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() {
                _nodes.remove(node);
                _edges.removeWhere(
                    (e) => e.fromId == node.id || e.toId == node.id);
              });
              Navigator.pop(ctx);
              _saveToLocalStorage();
            },
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteEdge(GsnEdge edge) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('エッジ削除'),
        content: const Text('この接続を削除しますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              setState(() => _edges.remove(edge));
              Navigator.pop(ctx);
              _saveToLocalStorage();
            },
            child: const Text('削除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GSNエディタ'),
        actions: [
          IconButton(
            icon: Icon(
                _deleteMode ? Icons.delete_forever : Icons.delete_outline),
            onPressed: _toggleDeleteMode,
            tooltip: '削除モード切替',
          ),
          IconButton(
              onPressed: _exportJson,
              icon: const Icon(Icons.save_alt),
              tooltip: 'JSON保存'),
        ],
      ),
      // Stackを使用して、キャンバスとパレットを重ねて表示
      body: Stack(
        children: [
          // DragTargetでキャンバス全体をラップし、ドロップを検知
          DragTarget<GsnNodeType>(
            builder: (context, candidateData, rejectedData) {
              return GestureDetector(
                onTapDown: (e) {
                  final sceneP = _tc.toScene(e.localPosition);
                  if (_deleteMode) {
                  } else if (_connecting != null) {
                    setState(() => _connecting = null);
                  } else {
                    for (var edge in List.from(_edges)) {
                      if (_hitTestEdge(sceneP, edge)) {
                        _confirmDeleteEdge(edge);
                        break;
                      }
                    }
                  }
                },
                child: InteractiveViewer(
                  transformationController: _tc,
                  minScale: 0.25,
                  maxScale: 4,
                  panEnabled: true,
                  scaleEnabled: true,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(2000),
                  child: SizedBox(
                    width: _worldSize.width,
                    height: _worldSize.height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: GsnEdgePainter(_nodes, _edges,
                                connectingId: _connecting),
                          ),
                        ),
                        ..._nodes.map((node) {
                          final isConnecting = _connecting == node.id;
                          return Positioned(
                            left: node.position.dx,
                            top: node.position.dy,
                            child: GestureDetector(
                              onTap: () => _handleTapNode(node),
                              onPanUpdate: (d) {
                                final scale = _tc.value.getMaxScaleOnAxis();
                                setState(() => node.position += d.delta / scale);
                              },
                              onPanEnd: (d) => _saveToLocalStorage(),
                              onDoubleTap: () =>
                                  !_deleteMode ? _editLabel(node) : null,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  if (isConnecting)
                                    Container(
                                      width: node.width,
                                      height: node.height,
                                      decoration: BoxDecoration(boxShadow: [
                                        BoxShadow(
                                          color: Colors.blue.withOpacity(0.8),
                                          blurRadius: 10,
                                          spreadRadius: 4,
                                        )
                                      ]),
                                    ),
                                  // ★ 変更: 汎用的なウィジェットビルダー関数を呼び出す
                                  _buildGsnShapeWidget(node),
                                  if (_deleteMode)
                                    Positioned(
                                      right: -8,
                                      top: -8,
                                      child: IconButton(
                                        icon: const Icon(Icons.close,
                                            size: 16, color: Colors.red),
                                        onPressed: () =>
                                            _confirmDeleteNode(node),
                                      ),
                                    ),
                                  Positioned(
                                    right: -8,
                                    bottom: -8,
                                    child: _ResizeHandle(
                                      onDrag: (dx, dy) {
                                        final scale =
                                            _tc.value.getMaxScaleOnAxis();
                                        setState(() {
                                          node.width = (node.width + dx / scale)
                                              .clamp(_minW, _maxW);
                                          node.height =
                                              (node.height + dy / scale)
                                                  .clamp(_minH, _maxH);
                                        });
                                      },
                                      onDragEnd: () => _saveToLocalStorage(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              );
            },
            // ドロップされた際の処理
            onAcceptWithDetails: (details) {
              // スクリーン座標をキャンバスのワールド座標に変換
              final scenePosition = _tc.toScene(details.offset);
              // 変換した座標にノードを追加
              _addNode(details.data, scenePosition);
            },
          ),
          // 画面左上にノードパレットを配置
          const Positioned(
            top: 10,
            left: 10,
            child: GsnPalette(),
          ),
        ],
      ),
    );
  }

  bool _hitTestEdge(Offset p, GsnEdge edge) {
    try {
      final fromNode = _nodes.firstWhere((n) => n.id == edge.fromId);
      final toNode = _nodes.firstWhere((n) => n.id == edge.toId);
      final a = fromNode.position + Offset(fromNode.width / 2, fromNode.height);
      final b = toNode.position + Offset(toNode.width / 2, 0);
      return _pointLineDistance(p, a, b) < 10;
    } catch (e) {
      return false;
    }
  }

  double _pointLineDistance(Offset p, Offset a, Offset b) {
    final l2 = (b - a).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    var t = ((p - a).dx * (b - a).dx + (p - a).dy * (b - a).dy) / l2;
    t = t.clamp(0, 1);
    final proj = a + (b - a) * t;
    return (p - proj).distance;
  }

  void _editLabel(GsnNode node) {
    final ctl = TextEditingController(text: node.label);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ノード名編集'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          TextButton(
            onPressed: () {
              if (ctl.text.isNotEmpty) {
                setState(() => node.label = ctl.text);
                _saveToLocalStorage();
              }
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _exportJson() {
    final data = {
      'nodes': _nodes.map((n) => n.toJson()).toList(),
      'edges': _edges.map((e) => e.toJson()).toList()
    };
    final str = const JsonEncoder.withIndent('  ').convert(data);
    final bytes = utf8.encode(str);
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', 'gsn.json')
      ..click();
    html.Url.revokeObjectUrl(url);
  }
}

// GSNノードの形状を描画する汎用的なウィジェットビルダー関数
// パレットとキャンバスの両方から利用できるように、Stateクラスの外に定義
Widget _buildGsnShapeWidget(GsnNode node, {bool isPalette = false}) {
  final label = Center(
    child: Padding(
      padding: const EdgeInsets.all(4.0),
      child: Text(
        node.label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          // パレット用はフォントを少し小さくする
          fontSize: isPalette ? 10 : 12,
        ),
        overflow: TextOverflow.ellipsis,
        maxLines: 5,
      ),
    ),
  );
  switch (node.type) {
    case GsnNodeType.goal:
      return Container(
        width: node.width,
        height: node.height,
        decoration:
            BoxDecoration(color: Colors.lightBlue.shade100, border: Border.all()),
        child: label,
      );
    case GsnNodeType.strategy:
      return CustomPaint(
        size: Size(node.width, node.height),
        painter: ParallelogramPainter(Colors.orangeAccent.shade100),
        child: SizedBox(width: node.width, height: node.height, child: label),
      );
    case GsnNodeType.evidence:
      return ClipOval(
        child: Container(
            width: node.width,
            height: node.height,
            color: Colors.greenAccent.shade100,
            child: label),
      );
    case GsnNodeType.context:
      return CustomPaint(
        size: Size(node.width, node.height),
        painter: RoundedRectPainter(Colors.purple.shade100, 12),
        child: SizedBox(width: node.width, height: node.height, child: label),
      );
    case GsnNodeType.assumption:
      return Container(
        width: node.width,
        height: node.height,
        decoration: BoxDecoration(
            color: Colors.yellowAccent.shade100, border: Border.all()),
        child: label,
      );
    case GsnNodeType.undeveloped:
      return CustomPaint(
        size: Size(node.width, node.height),
        painter: DiamondPainter(Colors.grey.shade400),
        child: SizedBox(width: node.width, height: node.height, child: label),
      );
  }
}


// ドラッグ＆ドロップ用のノードパレットウィジェット
class GsnPalette extends StatelessWidget {
  const GsnPalette({super.key});

  @override
  Widget build(BuildContext context) {
    // Cardで囲んで見やすくする
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: GsnNodeType.values
              .map((type) => _PaletteItem(type: type))
              .toList(),
        ),
      ),
    );
  }
}

// パレット内の各ノードアイテム
class _PaletteItem extends StatelessWidget {
  final GsnNodeType type;
  const _PaletteItem({required this.type});

  @override
  Widget build(BuildContext context) {
    // パレットに表示するためのダミーノードを作成
    final nodeForPalette = GsnNode(
      id: -1,
      type: type,
      position: Offset.zero,
      width: 80, // パレット内のサイズは固定
      height: 48,
      label: GsnNode._gsnTypeName(type),
    );

    // パレットに表示するウィジェット
    final child = _buildGsnShapeWidget(nodeForPalette, isPalette: true);

    // Draggableウィジェットでラップして、ドラッグ可能にする
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Draggable<GsnNodeType>(
        // ドラッグするデータ（ノード種別）
        data: type,
        // ドラッグ中にカーソル下に表示されるウィジェット
        feedback: Material(
          elevation: 4.0,
          color: Colors.transparent,
          child: child,
        ),
        // パレットに残る元のウィジェット
        child: child,
      ),
    );
  }
}


class _ResizeHandle extends StatelessWidget {
  final void Function(double dx, double dy) onDrag;
  final VoidCallback onDragEnd;
  const _ResizeHandle({required this.onDrag, required this.onDragEnd});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) => onDrag(d.delta.dx, d.delta.dy),
        onPanEnd: (d) => onDragEnd(),
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.black54),
            borderRadius: BorderRadius.circular(3),
            boxShadow: const [BoxShadow(blurRadius: 1, spreadRadius: 0)],
          ),
          child: const Icon(Icons.drag_handle, size: 12, color: Colors.black54),
        ),
      ),
    );
  }
}

class GsnEdgePainter extends CustomPainter {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;
  final int? connectingId;
  GsnEdgePainter(this.nodes, this.edges, {this.connectingId});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    final arrowPaint = Paint()..color = Colors.black;

    for (var e in edges) {
      try {
        final fromNode = nodes.firstWhere((n) => n.id == e.fromId);
        final toNode = nodes.firstWhere((n) => n.id == e.toId);

        final a = fromNode.position + Offset(fromNode.width / 2, fromNode.height);
        final b = toNode.position + Offset(toNode.width / 2, 0);

        canvas.drawLine(a, b, paint);

        const s = 10.0;
        final dir = (b - a).normalize();
        if (dir.distance == 0) continue;
        final perp = Offset(-dir.dy, dir.dx);
        final p1 = b - dir * s + perp * (s / 2);
        final p2 = b - dir * s - perp * (s / 2);
        final path = Path()
          ..moveTo(b.dx, b.dy)
          ..lineTo(p1.dx, p1.dy)
          ..lineTo(p2.dx, p2.dy)
          ..close();
        canvas.drawPath(path, arrowPaint);
      } catch (err) {
        // Node not found, skip drawing this edge
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class ParallelogramPainter extends CustomPainter {
  final Color color;
  ParallelogramPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final borderPaint = Paint()..color = Colors.black..strokeWidth = 1..style = PaintingStyle.stroke;
    final offset = size.width * 0.2;
    final path = Path()
      ..moveTo(offset, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - offset, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class RoundedRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  RoundedRectPainter(this.color, this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final borderPaint = Paint()..color = Colors.black..strokeWidth = 1..style = PaintingStyle.stroke;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Radius.circular(radius),
    );
    canvas.drawRRect(rect, paint);
    canvas.drawRRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class DiamondPainter extends CustomPainter {
  final Color color;
  DiamondPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final borderPaint = Paint()..color = Colors.black..strokeWidth = 1..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height / 2)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(0, size.height / 2)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

extension on Offset {
  Offset normalize() {
    final d = distance;
    return d == 0 ? this : this / d;
  }
}