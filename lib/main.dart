
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:html' as html;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MaterialApp(home: GsnEditor()));

enum GsnNodeType {
  goal,
  strategy,
  context,
  evidence,
  undeveloped,
  set,
  recordAccess,
  lambda,
  application,
  hub,
  map,
  stringLiteral,
  recordLabel,
  record
}

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
  }) : label = label ?? _gsnTypeName(type);

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
      case GsnNodeType.context:
        return 'Context';
      case GsnNodeType.evidence:
        return 'Evidence';
      case GsnNodeType.undeveloped:
        return 'Undeveloped';
      case GsnNodeType.set:
        return 'Set';
      case GsnNodeType.record:
        return 'Record';
      case GsnNodeType.recordAccess:
        return 'RecordAccess';
      case GsnNodeType.lambda:
        return 'Lambda';
      case GsnNodeType.application:
        return 'Application';
      case GsnNodeType.hub:
        return 'Hub';
      case GsnNodeType.map:
        return 'Map';
      case GsnNodeType.stringLiteral:
        return 'StringLiteral';
      case GsnNodeType.recordLabel:
        return 'RecordLabel';
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

  /// サーバーと通信してGSNの評価を実行する非同期関数
  Future<void> _evaluateOnServer() async {
    // Chromeで実行する場合、PCのIPアドレスではなく 'localhost' を使用
    const String pcIpAddress = 'localhost';
    final url = Uri.parse('http://$pcIpAddress:5000/evaluate');

    // 処理中を示すローディングインジケータを表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 現在のエディタの状態をJSONデータに変換
      final data = {
        'nodes': _nodes.map((n) => n.toJson()).toList(),
        'edges': _edges.map((e) => e.toJson()).toList()
      };
      final jsonString = jsonEncode(data);

      // サーバーにHTTP POSTリクエストを送信 (タイムアウトを15秒に設定)
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: jsonString,
      ).timeout(const Duration(seconds: 15));

      Navigator.pop(context); // ローディングインジケータを閉じる

      // サーバーからの応答を処理
      if (response.statusCode == 200) {
        // 成功: 結果を整形してダイアログに表示
        final decodedJson = jsonDecode(utf8.decode(response.bodyBytes)); // 日本語文字化け対応
        final prettyJson = const JsonEncoder.withIndent('  ').convert(decodedJson);
        _showResultDialog('評価結果', prettyJson);
      } else {
        // サーバー側エラー: エラーメッセージを表示
        final errorJson = jsonDecode(utf8.decode(response.bodyBytes));
        _showResultDialog('サーバーエラー', 'Status: ${response.statusCode}\nMessage: ${errorJson['error']}');
      }
    } catch (e) {
      // 通信エラー: エラーメッセージを表示
      Navigator.pop(context); // ローディングインジケータを閉じる
      _showResultDialog('通信エラー', 'サーバーに接続できませんでした。\n$e');
    }
  }

  /// 結果表示用の汎用ダイアログ
  void _showResultDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Scrollbar(
          child: SingleChildScrollView(
            child: Text(content),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
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
           IconButton(
              onPressed: _evaluateOnServer,
              icon: const Icon(Icons.play_arrow), // アイコンを再生マークに変更
              tooltip: 'サーバーで評価'),
        ],
      ),
      body: Stack(
        children: [
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
                              behavior: HitTestBehavior.opaque,
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
            onAcceptWithDetails: (details) {
              final scenePosition = _tc.toScene(details.offset);
              _addNode(details.data, scenePosition);
            },
          ),
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

    // ダイアログで使う関数を先に定義する
    void submit() {
      if (ctl.text.isNotEmpty) {
        setState(() => node.label = ctl.text);
        _saveToLocalStorage();
      }
      Navigator.pop(context);
    }

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ノード名編集'),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (_) => submit()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル')),
          TextButton(
            onPressed: submit,
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


Widget _buildGsnShapeWidget(GsnNode node, {bool isPalette = false}) {
  final labelStyle = TextStyle(
    fontSize: isPalette ? 10 : 12,
    fontWeight: FontWeight.bold,
    color: node.type == GsnNodeType.set || node.type == GsnNodeType.map ? Colors.white : Colors.black,
  );

  final label = Center(
    child: Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text(
        node.label,
        textAlign: TextAlign.center,
        style: labelStyle,
        overflow: TextOverflow.ellipsis,
        maxLines: isPalette ? 2 : 5,
      ),
    ),
  );

  Widget buildPainter(CustomPainter painter) {
    return CustomPaint(
      size: Size(node.width, node.height),
      painter: painter,
      child: SizedBox(width: node.width, height: node.height, child: label),
    );
  }

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
      return buildPainter(ParallelogramPainter(Colors.orangeAccent.shade100));
    case GsnNodeType.evidence:
      return buildPainter(EvidencePainter());
    case GsnNodeType.undeveloped:
      return buildPainter(UndevelopedPainter());
    case GsnNodeType.set:
      return buildPainter(SetPainter());
    case GsnNodeType.record:
      return buildPainter(RecordPainter());
    case GsnNodeType.lambda:
      return buildPainter(LambdaPainter());
    case GsnNodeType.application:
    // もしパレット上ならラベルを表示し、キャンバス上なら表示しない
      if (isPalette) {
        return buildPainter(ApplicationPainter()); // buildPainterはPainterとlabelを両方描画する
      } else {
        // CustomPaintを直接使ってPainterのみ描画する
        return CustomPaint(
          size: Size(node.width, node.height),
          painter: ApplicationPainter(),
        );
      }
    case GsnNodeType.hub:
    // もしパレット上ならラベルを表示し、キャンバス上なら表示しない
      if (isPalette) {
        return buildPainter(HubPainter()); // buildPainterはPainterとlabelを両方描画する
      } else {
        // CustomPaintを直接使ってPainterのみ描画する
        return CustomPaint(
          size: Size(node.width, node.height),
          painter: HubPainter(),
        );
      }
    case GsnNodeType.map:
      if (isPalette) {
        return buildPainter(MapPainter());
      } else {
        return CustomPaint(
          size: Size(node.width, node.height),
          painter: MapPainter(),
        );
      }

    case GsnNodeType.stringLiteral:
      return label;
    case GsnNodeType.recordLabel:
      // CustomPaintを直接使い、painterにnode.labelを渡す
      return CustomPaint(
        size: Size(node.width, node.height),
        painter: RecordLabelPainter(label: node.label),
      );
    case GsnNodeType.recordAccess:

      // CustomPaintを直接使い、painterにnode.labelを渡す
      return CustomPaint(
        size: Size(node.width, node.height),
        painter: RecordAccessPainter(label: node.label),
      );

    case GsnNodeType.context:
      return buildPainter(RoundedRectPainter(Colors.purple.shade100, 12));

  }
}

class GsnPalette extends StatelessWidget {
  const GsnPalette({super.key});

  @override
  Widget build(BuildContext context) {
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

class _PaletteItem extends StatelessWidget {
  final GsnNodeType type;
  const _PaletteItem({required this.type});

  @override
  Widget build(BuildContext context) {
    final nodeForPalette = GsnNode(
      id: -1,
      type: type,
      position: Offset.zero,
      width: 80,
      height: 48,
      label: GsnNode._gsnTypeName(type),
    );

    final child = _buildGsnShapeWidget(nodeForPalette, isPalette: true);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Draggable<GsnNodeType>(
        data: type,
        feedback: Material(
          elevation: 4.0,
          color: Colors.transparent,
          child: child,
        ),
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

        // デフォルトの接続点を定義 (ノードの上下中央)
        var a = fromNode.position + Offset(fromNode.width / 2, fromNode.height);
        var b = toNode.position + Offset(toNode.width / 2, 0);

        // もし開始ノードがLambdaなら、接続点を三角形の先端に上書き
        if (fromNode.type == GsnNodeType.application) {
          a = fromNode.position +
              Offset(fromNode.width * 0.75, fromNode.height * 0.5);
        }

        //  もし終了ノードがLambdaなら、接続点を三角形の先端に上書き
        if (toNode.type == GsnNodeType.application) {
          b = toNode.position + Offset(toNode.width * 0.25, toNode.height * 0.5);
        }

        //  もし開始ノードがLambdaなら、接続点を三角形の先端に上書き
        if (fromNode.type == GsnNodeType.lambda) {
          a = fromNode.position +
              Offset(-fromNode.width * 0.1, fromNode.height * 0.5);
        }

        //  もし終了ノードがLambdaなら、接続点を三角形の先端に上書き
        if (toNode.type == GsnNodeType.lambda) {
          b = toNode.position + Offset(-toNode.width * 0.1, toNode.height * 0.5);
        }



        //  もし開始ノードがHubなら、相手に最も近い接続点を選ぶ
        if (fromNode.type == GsnNodeType.hub) {
          final hubTop = fromNode.position + Offset(fromNode.width * 0.5, 0);
          final hubBottom =
              fromNode.position + Offset(fromNode.width * 0.5, fromNode.height);
          final hubRight =
              fromNode.position + Offset(fromNode.width, fromNode.height * 0.5);

          final distTop = (b - hubTop).distanceSquared;
          final distBottom = (b - hubBottom).distanceSquared;
          final distRight = (b - hubRight).distanceSquared;

          if (distTop < distBottom && distTop < distRight) {
            a = hubTop;
          } else if (distBottom < distRight) {
            a = hubBottom;
          } else {
            a = hubRight;
          }
        }

        // もし終了ノードがHubなら、相手に最も近い接続点を選ぶ
        if (toNode.type == GsnNodeType.hub) {
          final hubTop = toNode.position + Offset(toNode.width * 0.5, 0);
          final hubBottom =
              toNode.position + Offset(toNode.width * 0.5, toNode.height);
          final hubRight =
              toNode.position + Offset(toNode.width, toNode.height * 0.5);

          final distTop = (a - hubTop).distanceSquared;
          final distBottom = (a - hubBottom).distanceSquared;
          final distRight = (a - hubRight).distanceSquared;

          if (distTop < distBottom && distTop < distRight) {
            b = hubTop;
          } else if (distBottom < distRight) {
            b = hubBottom;
          } else {
            b = hubRight;
          }
        }

        canvas.drawLine(a, b, paint);
// ルールに基づいて矢印を描くかどうかを判断
        // 「接続先ノードがContextでもGoalでもない」場合にtrueになる
        final bool shouldDrawArrow =
          toNode.type != GsnNodeType.hub && toNode.type != GsnNodeType.recordAccess && toNode.type != GsnNodeType.recordLabel && toNode.type != GsnNodeType.map;

        // shouldDrawArrowがtrueの場合のみ、矢印を描画する
        if (shouldDrawArrow) {
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
        }
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

class EvidencePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 白い塗りつぶしのPaintオブジェクト
    final fillPaint = Paint()..color = Colors.white;
    // 黒い枠線のPaintオブジェクト
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke; // スタイルをstroke（線のみ）に設定

    // 描画する矩形
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    // まず白い円（楕円）を塗りつぶして描画
    canvas.drawOval(rect, fillPaint);
    // 次にその上に黒い枠線を描画
    canvas.drawOval(rect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class UndevelopedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // 菱形を描画するためのパスを作成
    final path = Path()
      // 上辺の中央からスタート
      ..moveTo(size.width / 2, 0)
      // 右辺の中央へ線を引く
      ..lineTo(size.width, size.height / 2)
      //  下辺の中央へ線を引く
      ..lineTo(size.width / 2, size.height)
      // 左辺の中央へ線を引く
      ..lineTo(0, size.height / 2)
      // パスを閉じて始点へ戻る
      ..close();

    // 作成したパスを描画
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class RecordPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    //  白い塗りつぶしの設定
    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // 黒い枠線の設定
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    //描画領域いっぱいの四角形を定義
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    //白い円（楕円）を塗りつぶして描画
    canvas.drawOval(rect, fillPaint);
    //その上に黒い枠線を描画
    canvas.drawOval(rect, borderPaint);
  }
   @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
class SetPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 黒い塗りつぶしのPaintオブジェクトを作成
    final borderPaint = Paint()
      ..color = Colors.black // 色を黒に設定
      ..style = PaintingStyle.fill; // スタイルをfill（塗りつぶし）に設定

    canvas.drawOval(Rect.fromLTWH(0, 0, size.width, size.height), borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class LambdaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawOval(rect, paint);
    canvas.drawOval(rect, borderPaint);


    final trianglePath = Path()
    // 右辺の少し外側からスタート
      ..moveTo(-size.width * 0.1, size.height * 0.25)
    // 右に突き出る頂点へ線を引く
       ..lineTo( - 1, size.height * 0.5)
    //右辺の少し外側に戻る
       ..lineTo(-size.width  * 0.1, size.height * 0.75)
      ..close();
    canvas.drawPath(trianglePath, paint);
    canvas.drawPath(trianglePath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ApplicationPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(size.width * 0.25, size.height * 0.5)
      ..lineTo(size.width * 0.75, 0)
      ..lineTo(size.width * 0.75, size.height)
      ..close();
    canvas.drawPath(path, borderPaint);
  }
   @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class HubPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;

    canvas.drawLine(Offset(size.width * 0.5, 0), Offset(size.width*0.5, size.height), paint);
    canvas.drawLine(Offset(size.width * 0.5, size.height*0.5), Offset(size.width, size.height*0.5), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black;
    final linePaint = Paint()..color = Colors.black..strokeWidth = 2;

    final rectSize = size.width * 0.4;
    final rect = Rect.fromCenter(
      center: Offset(size.width * 0.5, size.height * 0.5),
      width: rectSize,
      height: rectSize,
    );
    canvas.drawRect(rect, paint);

    canvas.drawLine(Offset(size.width * 0.5, 0), Offset(size.width*0.5, rect.top), linePaint);
    canvas.drawLine(Offset(size.width * 0.5, rect.bottom), Offset(size.width*0.5, size.height), linePaint);
    canvas.drawLine(Offset(rect.right, size.height * 0.5), Offset(size.width, size.height * 0.5), linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


class RecordLabelPainter extends CustomPainter {
  final String label;

  RecordLabelPainter({required this.label});

  @override
  void paint(Canvas canvas, Size size) {
    //左側に縦線を描画する
    final linePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    final lineX = size.width / 2; // 線のX座標
    canvas.drawLine(Offset(lineX, 0), Offset(lineX, size.height), linePaint);

    //表示する文字のスタイルを準備する
    final textSpan = TextSpan(
      text: label,
      style: const TextStyle(
        color: Colors.black,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    );

    //文字を描画するためのTextPainterを準備する
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      maxLines: 5, // 複数行を許容
      ellipsis: '...', // はみ出した場合は...で省略
    );

    //文字をレイアウトする (どこにどのサイズで描画するか計算)
    final textStartX = lineX + 10.0; // 線の右側10pxの位置から文字を開始
    final availableWidth = size.width - textStartX; // 文字が使える横幅
    textPainter.layout(
        minWidth: 0, maxWidth: availableWidth > 0 ? availableWidth : 0);

    // 計算された位置に文字を実際に描画する
    // Y座標を計算して、上下中央に配置する
    final offsetY = (size.height - textPainter.height) / 2;
    textPainter.paint(canvas, Offset(textStartX, offsetY));
  }

  @override
  bool shouldRepaint(covariant RecordLabelPainter oldDelegate) {
    // ラベルが変更された場合のみ再描画する
    return oldDelegate.label != label;
  }
}


class RecordAccessPainter extends CustomPainter {
  final String label;

  RecordAccessPainter({required this.label});

  @override
  void paint(Canvas canvas, Size size) {
    // 右端に縦線を描画する
    final linePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    // ノードの右端から5px内側に線を引く
    final lineX = size.width / 2;
    canvas.drawLine(Offset(lineX, 0), Offset(lineX, size.height), linePaint);

    //表示する文字を準備する (TextPainter)
    final textSpan = TextSpan(
      text: label,
      style: const TextStyle(
        color: Colors.black,
        fontSize: 12,
        fontWeight: FontWeight.bold,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      maxLines: 5,
      ellipsis: '...', // はみ出した場合は...
    );

    //文字が使用できる横幅を計算してレイアウトする
    const textPaddingRight = 8.0; // 文字と線の間の余白
    final availableWidth = lineX - textPaddingRight;
    textPainter.layout(
        minWidth: 0, maxWidth: availableWidth > 0 ? availableWidth : 0);

    // 計算された位置に文字を描画する
    // Y座標を計算して、上下中央に配置
    final textOffsetY = (size.height - textPainter.height) / 2;
    // X座標は0から開始（左端から描画）
    textPainter.paint(canvas, Offset(0, textOffsetY));
  }

  @override
  bool shouldRepaint(covariant RecordAccessPainter oldDelegate) {
    // ラベルが変更された場合のみ再描画
    return oldDelegate.label != label;
  }
}


extension on Offset {
  Offset normalize() {
    final d = distance;
    return d == 0 ? this : this / d;

  }
}
