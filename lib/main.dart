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

  // ★ JSONからオブジェクトを復元するためのファクトリコンストラクタ
  factory GsnNode.fromJson(Map<String, dynamic> json) {
    return GsnNode(
      id: json['id'],
      type: GsnNodeType.values.firstWhere(
        (e) => _gsnTypeName(e) == json['gsn_type'],
        orElse: () => GsnNodeType.goal, // 見つからない場合のデフォルト値
      ),
      position: Offset(json['position_x'], json['position_y']),
      width: json['width'] ?? 100,
      height: json['height'] ?? 60,
      label: json['description'],
    );
  }

  // ★ 永続化のために位置とサイズも保存するよう修正
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

  // ★ JSONからオブジェクトを復元するためのファクトリコンストラクタ
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
  // パン／ズーム用
  final TransformationController _tc = TransformationController();
  final Size _worldSize = const Size(4000, 4000); // 広いキャンバス

  final List<GsnNode> _nodes = [];
  final List<GsnEdge> _edges = [];
  int _nodeCounter = 0;
  bool _deleteMode = false;
  int? _connecting;

  // リサイズ制約
  static const double _minW = 60;
  static const double _minH = 40;
  static const double _maxW = 800;
  static const double _maxH = 600;

  // ★ アプリ起動時にデータを読み込む
  @override
  void initState() {
    super.initState();
    _loadFromLocalStorage();
  }

  // ★========== データ永続化処理 ==========★
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
  // ★====================================★

  void _addNode(GsnNodeType type) {
    final viewSize = MediaQuery.of(context).size;
    final sceneCenter =
        _tc.toScene(Offset(viewSize.width / 2, viewSize.height / 2));
    setState(() {
      _nodes.add(GsnNode(
        id: _nodeCounter++,
        type: type,
        position: sceneCenter,
      ));
    });
    _saveToLocalStorage(); // ★保存
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
        _saveToLocalStorage(); // ★保存
      } else {
        // 同じノードを再度タップした場合は接続モードを解除
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
              _saveToLocalStorage(); // ★保存
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
              _saveToLocalStorage(); // ★保存
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
          PopupMenuButton<GsnNodeType>(
            onSelected: _addNode,
            itemBuilder: (_) => const [
              PopupMenuItem(value: GsnNodeType.goal, child: Text('Goal')),
              PopupMenuItem(
                  value: GsnNodeType.strategy, child: Text('Strategy')),
              PopupMenuItem(
                  value: GsnNodeType.evidence, child: Text('Evidence')),
              PopupMenuItem(
                  value: GsnNodeType.context, child: Text('Context')),
              PopupMenuItem(
                  value: GsnNodeType.assumption, child: Text('Assumption')),
              PopupMenuItem(
                  value: GsnNodeType.undeveloped, child: Text('Undeveloped')),
            ],
            icon: const Icon(Icons.add_box),
            tooltip: 'ノード追加',
          ),
          IconButton(
              onPressed: _exportJson,
              icon: const Icon(Icons.save_alt),
              tooltip: 'JSON保存'),
        ],
      ),
      body: GestureDetector(
        onTapDown: (e) {
          final sceneP = _tc.toScene(e.localPosition);
          if (_deleteMode) {
             // 削除モード時はエッジ削除しない
          } else if (_connecting != null) {
            // 接続モード中にキャンバスをタップしたら解除
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
                    painter: GsnEdgePainter(_nodes, _edges, connectingId: _connecting),
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
                      onPanEnd: (d) => _saveToLocalStorage(), // ★ドラッグ終了時に保存
                      onDoubleTap: () => !_deleteMode ? _editLabel(node) : null,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // 接続元ノードをハイライト
                          if (isConnecting)
                             Container(
                                width: node.width,
                                height: node.height,
                                decoration: BoxDecoration(
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.blue.withOpacity(0.8),
                                      blurRadius: 10,
                                      spreadRadius: 4,
                                    )
                                  ]
                                ),
                             ),
                          _buildShape(node),
                          if (_deleteMode)
                            Positioned(
                              right: -8,
                              top: -8,
                              child: IconButton(
                                icon: const Icon(Icons.close,
                                    size: 16, color: Colors.red),
                                onPressed: () => _confirmDeleteNode(node),
                              ),
                            ),
                          Positioned(
                            right: -8,
                            bottom: -8,
                            child: _ResizeHandle(
                              onDrag: (dx, dy) {
                                final scale = _tc.value.getMaxScaleOnAxis();
                                setState(() {
                                  node.width = (node.width + dx / scale)
                                      .clamp(_minW, _maxW);
                                  node.height = (node.height + dy / scale)
                                      .clamp(_minH, _maxH);
                                });
                              },
                              onDragEnd: () => _saveToLocalStorage(), // ★リサイズ終了時に保存
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
      return false; // ノードが見つからない場合はヒットしない
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
                _saveToLocalStorage(); // ★保存
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

  Widget _buildShape(GsnNode node) {
    final label = Center(
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: Text(
          node.label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
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
          child:
              SizedBox(width: node.width, height: node.height, child: label),
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
          child:
              SizedBox(width: node.width, height: node.height, child: label),
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
          child:
              SizedBox(width: node.width, height: node.height, child: label),
        );
    }
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
        onPanEnd: (d) => onDragEnd(), // ★ドラッグ終了イベント
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
        // ノードが見つからない場合はスキップ
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