import 'dart:math';
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
  record,
  x
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
      case GsnNodeType.x:
        return 'X';
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
      case GsnNodeType.x:
        return 'X';
    }
  }

  Future<void> _evaluateGsn() async {

    // 送信データ作成
    final requestData = {
      "nodes": _nodes.map((n) => {
        "id": n.id,
        "gsn_type":_gsnTypeName(n.type),
        "description": n.label,
        "position_x": n.position.dx,
        "position_y": n.position.dy,
        "width": n.width,
        "height": n.height,
      }).toList(),
      "edges":_edges.map((e) => {"from": e.fromId, "to": e.toId}).toList(),
    };

    try {
      // サーバーへ送信
      final response = await http.post(
        Uri.parse('http://127.0.0.1:5000/evaluate'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(requestData),
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> result = jsonDecode(utf8.decode(response.bodyBytes));

        // ★ここが変更点: メイン変数は更新せず、一時的なリストを作成
        final List<dynamic> nodeData = result['nodes'] ?? [];
        final List<GsnNode> resultNodes = nodeData
            .map((data) => GsnNode.fromJson(data))
            .toList();

        final List<dynamic> edgeData = result['edges'] ?? [];
        final List<GsnEdge> resultEdges = edgeData
          .map((data) => GsnEdge.fromJson(data))
          .toList();
        // ★ビューアをダイアログとして開く
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => GsnResultViewer(
              nodes: resultNodes,
              edges: resultEdges
            ),
          );
        }

      } else {
        _showErrorDialog("評価エラー: ${response.statusCode}\n${response.body}");
      }
    } catch (e) {
      _showErrorDialog("通信エラー: $e");
    }

  }
// エラーを表示するための共通関数
  void _showErrorDialog(String message) {
    if (!mounted) return; // 画面が存在しない場合は何もしない

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("エラー"),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("OK"),
          ),
        ],
      ),
    );
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

  //図を一括で削除
  Future<void> _confirmClearDiagram() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('図の全削除'),
        content: const Text('現在表示されているすべてのノードとエッジを削除し、エディタをリセットします。よろしいですか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('すべて削除'),
          ),
        ],
      ),
    );

    if (result == true) {
      setState(() {
        _nodes.clear();
        _edges.clear();
        _nodeCounter = 0;
        _connecting = null;
        _deleteMode = false;
      });
      _saveToLocalStorage();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('図がリセットされました。')),
      );
    }
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

  /// サーバからGSN図の構造（ノードとエッジ）を読み込む
  /*Future<void> _loadDiagramFromServer() async {
    // 1. ローディングダイアログを表示
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Center(child: CircularProgressIndicator());
      },
    );

    // 2. サーバの新しいエンドポイントを指定
    final url = Uri.parse('http://127.0.0.1:5000/get-diagram');

    try {
      final response = await http.get(url).timeout(const Duration(seconds: 10));

      Navigator.pop(context); // ローディングダイアログを閉じる

      if (response.statusCode == 200) {
        // 3. サーバから受け取ったJSONデータをデコード
        final Map<String, dynamic> data = jsonDecode(utf8.decode(response.bodyBytes));

        // 4. JSONから新しいノードとエッジのリストを作成
        final newNodes = (data['nodes'] as List)
            .map((nodeData) => GsnNode.fromJson(nodeData))
            .toList();

        final newEdges = (data['edges'] as List)
            .map((edgeData) => GsnEdge.fromJson(edgeData))
            .toList();

        // 5. ★★★ finalエラー修正箇所 ★★★
        // setStateの中で、リストの「中身」だけを入れ替える
        setState(() {
          // 古いデータをすべて削除
          _nodes.clear();
          _edges.clear();

          // 新しいデータを追加
          _nodes.addAll(newNodes);
          _edges.addAll(newEdges);

          // 次に作成するノードIDを更新
          if (_nodes.isNotEmpty) {
            // max() を使うために 'dart:math' が必要
            _nodeCounter = _nodes.map((n) => n.id).reduce(max) + 1;
          } else {
            _nodeCounter = 1;
          }
        });
        // ★★★ ここまでがパースと描画の核心部です ★★★

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('サーバから図を読み込みました。')),
        );
      } else {
        // サーバが 404 や 500 エラーを返した場合
        _showResultDialog('読込エラー',
            'サーバから図を読み込めませんでした。\nStatus: ${response.statusCode}');
      }
    } catch (e) {
      // 通信タイムアウトや接続失敗
      Navigator.pop(context); // ローディングを閉じる
      _showResultDialog('通信エラー', 'サーバに接続できませんでした。\n$e');
    }
  }*/
  // ----------------------------------------------------
// 【追加対象】_GsnEditorState クラスに追加する _importJson メソッド
// ----------------------------------------------------

  // 新しいメソッド: ローカルのJSONファイルから図を読み込む
  void _importJson() {
    // 1. HTMLのファイル入力要素を作成
    final input = html.FileUploadInputElement()..accept = '.json';
    input.click(); // ファイル選択ダイアログを開く

    input.onChange.listen((e) {
      final files = input.files;
      if (files!.isEmpty) return;

      final file = files[0];
      final reader = html.FileReader();

      // 2. ファイルをテキストとして読み込む
      reader.onLoadEnd.listen((e) {
        try {
          final jsonString = reader.result as String;
          final data = jsonDecode(jsonString);

          // 3. データのパースと状態の更新
          final newNodes = (data['nodes'] as List)
              .map((nodeData) => GsnNode.fromJson(nodeData))
              .toList();

          final newEdges = (data['edges'] as List)
              .map((edgeData) => GsnEdge.fromJson(edgeData))
              .toList();

          setState(() {
            _nodes.clear();
            _edges.clear();
            _nodes.addAll(newNodes);
            _edges.addAll(newEdges);

            // ノードカウンターの更新
            if (_nodes.isNotEmpty) {
              // max() を使うために 'dart:math' が必要
              _nodeCounter = _nodes.map((n) => n.id).reduce(max) + 1;
            } else {
              _nodeCounter = 1;
            }
          });

          _saveToLocalStorage();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ローカルファイルから図を読み込みました。')),
          );

        } catch (e) {
          _showResultDialog('読込エラー', 'ファイルの解析に失敗しました。\n$e');
        }
      });

      reader.readAsText(file, 'utf-8');
    });
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
              onPressed: _evaluateGsn,
              icon: const Icon(Icons.play_arrow), // アイコンを再生マークに変更
              tooltip: 'サーバーで評価'),
          /*IconButton(
            icon: const Icon(Icons.cloud_download),
            tooltip: 'サーバから読み込み',
            onPressed: _loadDiagramFromServer, // <-- 作成した関数を呼び出す
          ),*/
          // ローカルファイルから読み込むボタン
          IconButton(
            onPressed: _importJson,
            icon: const Icon(Icons.folder_open),
            tooltip: 'ローカルJSON読み込み',
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '図をすべて削除（リセット）',
            onPressed: _confirmClearDiagram, // <-- 新しいメソッドを呼び出す
          ),
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
        // ここを新しいクラス名に置き換える
        return buildPainter(ApplicationPainter()); // buildPainterはPainterとlabelを両方描画する
      } else {
        // CustomPaintを直接使ってPainterのみ描画する
        return CustomPaint(
          size: Size(node.width, node.height),
          // ここを新しいクラス名に置き換える
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

    case GsnNodeType.x:
      return buildPainter(XPainter());
  }
}

class GsnPalette extends StatelessWidget {
  const GsnPalette({super.key});

  @override
  Widget build(BuildContext context) {
    // 画面の高さを取得
    final screenHeight = MediaQuery.of(context).size.height;

    return Card(
      elevation: 4,
      child: Container(
        // パレットの高さを画面の80%に制限（これを超えるとスクロールする）
        constraints: BoxConstraints(
          maxHeight: screenHeight * 0.8,
        ),
        padding: const EdgeInsets.all(8.0),
        // ここでスクロール可能にする
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: GsnNodeType.values
                .map((type) => _PaletteItem(type: type))
                .toList(),
          ),
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

// main.dart ファイル内の既存の GsnEdgePainter クラスを
// 以下のコードで「置き換え」てください。

class GsnEdgePainter extends CustomPainter {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;
  final int? connectingId;
  final bool isRemovalMode;

  GsnEdgePainter(
    this.nodes,
    this.edges, {
    this.connectingId,
    this.isRemovalMode = false,
  });

  // ノードの矩形上で、指定された点(point)に最も近い辺上の点を計算する
  Offset _getNearestPointOnRect(Rect rect, Offset point) {
    // ノードの中心
    final center = rect.center;
    // 中心から指定点へのベクトル
    final dir = point - center;

    // ノードの辺（上下左右）の座標
    final left = rect.left;
    final right = rect.right;
    final top = rect.top;
    final bottom = rect.bottom;

    // ベクトルがどの辺と交差するかを計算
    // (t = 0.5 のとき辺にぶつかる)
    final dx = dir.dx.abs() * rect.height;
    final dy = dir.dy.abs() * rect.width;

    if (dx > dy) {
      // 左右の辺に接続する場合
      final t = (rect.width / 2) / dir.dx.abs();
      // Y座標は中心から dir.dy の傾きで計算
      final yOffset = center.dy + dir.dy * t;

      return dir.dx > 0
          ? Offset(right, yOffset) // 右辺に接続
          : Offset(left, yOffset);  // 左辺に接続
    } else {
      // 上下の辺に接続する場合 (X座標をノードの中心に固定)
      return dir.dy > 0
          ? Offset(center.dx, bottom)
          : Offset(center.dx, top);
    }
  }

  // ----------------------------------------------------
  // Helper: 特殊ノードの接続候補点リストを取得
  // ----------------------------------------------------
  List<Offset> _getSpecialPoints(GsnNode node, Rect rect) {
    if (node.type == GsnNodeType.lambda) {
      // Lambdaノードの接続点 (左側のT-コネクタの上下端)
      const double wRatioTee = 0.25;
      final double wTee = node.width * wRatioTee;
      final double tBarX = rect.left + wTee / 2;

      final specialTop = Offset(tBarX, rect.top);
      final specialBottom = Offset(tBarX, rect.bottom);
      return [specialTop, specialBottom];
    } else if (node.type == GsnNodeType.application) {
      // Applicationノードの接続点 (縦線の上、下、右端)
      const double hubRatio = 0.4;
      const double hubCenterRatio = hubRatio * 0.5;
      final double lineX = rect.left + node.width * hubCenterRatio;

      final specialTop = Offset(lineX, rect.top);
      final specialBottom = Offset(lineX, rect.bottom);
      final specialRight = Offset(rect.right, rect.center.dy);
      return [specialTop, specialBottom, specialRight];
    } else if (node.type == GsnNodeType.map) {
      // Mapノードの接続点 (シンボルの中央線上の黒い四角形の上端、下端、右端)
      final rectSize = node.width * 0.4;
      final halfRectSize = rectSize / 2;

      final lineX = rect.center.dx;
      final rectTopY = rect.center.dy - halfRectSize;
      final rectBottomY = rect.center.dy + halfRectSize;

      final specialTop = Offset(lineX, rectTopY);
      final specialBottom = Offset(lineX, rectBottomY);
      final specialRight = Offset(rect.right, rect.center.dy);
      return [specialTop, specialBottom, specialRight];
    }
    return [];
  }

  // ----------------------------------------------------
  // paint メソッド本体
  // ----------------------------------------------------
  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in edges) {
      final GsnNode fromNode;
      final GsnNode toNode;

      try {
        fromNode = nodes.firstWhere((n) => n.id == edge.fromId);
        toNode = nodes.firstWhere((n) => n.id == edge.toId);
      } catch (e) {
        continue;
      }

      final isSelected = (connectingId == fromNode.id || connectingId == toNode.id);

      final paint = Paint()
        ..color = isRemovalMode
            ? Colors.red.withOpacity(0.5)
            : (isSelected ? Colors.blue.shade800 : Colors.black)
        ..strokeWidth = isSelected ? 3 : 2;

Offset startPoint, endPoint;

      // 特殊ノード判定
      final bool fromIsLambda = fromNode.type == GsnNodeType.lambda;
      final bool toIsLambda = toNode.type == GsnNodeType.lambda;
      final bool fromIsApplication = fromNode.type == GsnNodeType.application;
      final bool toIsApplication = toNode.type == GsnNodeType.application;
      final bool fromIsMap = fromNode.type == GsnNodeType.map;
      final bool toIsMap = toNode.type == GsnNodeType.map;
      final bool fromIsSpecial = fromIsLambda || fromIsApplication || fromIsMap;
      final bool toIsSpecial = toIsLambda || toIsApplication || toIsMap;

      // ----------------------------------------------------
      // Case 1 & 2: 両方のノードが特殊ノードの場合 (同じ種類同士も含む)
      // ----------------------------------------------------
      if (fromIsSpecial && toIsSpecial) {
          // 修正: fromIsSpecial && toIsSpecial の条件で統一的な処理を行う
          final fromRect = Rect.fromLTWH(fromNode.position.dx, fromNode.position.dy, fromNode.width, fromNode.height);
          final toRect = Rect.fromLTWH(toNode.position.dx, toNode.position.dy, toNode.width, toNode.height);

          final fromPoints = _getSpecialPoints(fromNode, fromRect);
          final toPoints = _getSpecialPoints(toNode, toRect);

          double minDistanceSquared = double.infinity;
          Offset closestStartPoint = Offset.zero;
          Offset closestEndPoint = Offset.zero;

          // 総当たりで最短距離のペアを探す
          for (final p1 in fromPoints) {
              for (final p2 in toPoints) {
                  final distSquared = (p1 - p2).distanceSquared;
                  if (distSquared < minDistanceSquared) {
                      minDistanceSquared = distSquared;
                      closestStartPoint = p1;
                      closestEndPoint = p2;
                  }
              }
          }

          startPoint = closestStartPoint;
          endPoint = closestEndPoint;

      } else if (fromIsSpecial || toIsSpecial) {

          // ----------------------------------------------------
          // Case 3: 片方のみが特殊ノードの場合 (既存の優先度ロジックを保持)
          // ----------------------------------------------------

          GsnNode specialNode;
          GsnNode otherNode;
          // GsnNodeType specialType; // 使用しないため削除

          // 優先度: Lambda > Application > Map
          if (fromIsLambda || toIsLambda) {
              specialNode = fromIsLambda ? fromNode : toNode;
              otherNode = fromIsLambda ? toNode : fromNode;
          } else if (fromIsApplication || toIsApplication) {
              specialNode = fromIsApplication ? fromNode : toNode;
              otherNode = fromIsApplication ? toNode : fromNode;
          } else {
              specialNode = fromIsMap ? fromNode : toNode;
              otherNode = fromIsMap ? toNode : fromNode;
          }

          final specialNodeRect = Rect.fromLTWH(specialNode.position.dx, specialNode.position.dy, specialNode.width, specialNode.height);
          final otherNodeRect = Rect.fromLTWH(otherNode.position.dx, otherNode.position.dy, otherNode.width, otherNode.height);
          final otherCenter = otherNodeRect.center;

          // specialNodeのタイプに基づいて接続候補点を計算
          List<Offset> points = _getSpecialPoints(specialNode, specialNodeRect);

          // 相手ノードの中心に最も近い接続ポイントを選択
          final closestSpecialPoint = points.reduce((a, b) =>
              (a - otherCenter).distanceSquared < (b - otherCenter).distanceSquared
                  ? a
                  : b);

          // 接続点の決定
          if (specialNode == fromNode) {
              startPoint = closestSpecialPoint;
              endPoint = _getNearestPointOnRect(otherNodeRect, closestSpecialPoint);
          } else {
              startPoint = _getNearestPointOnRect(otherNodeRect, closestSpecialPoint);
              endPoint = closestSpecialPoint;
          }
      } else {
          // ----------------------------------------------------
          // Case 4: 通常ノード同士の接続
          // ----------------------------------------------------
          final fromRect = Rect.fromLTWH(
            fromNode.position.dx,
            fromNode.position.dy,
            fromNode.width,
            fromNode.height,
          );
          final toRect = Rect.fromLTWH(
            toNode.position.dx,
            toNode.position.dy,
            toNode.width,
            toNode.height,
          );

          startPoint = _getNearestPointOnRect(fromRect, toRect.center);
          endPoint = _getNearestPointOnRect(toRect, fromRect.center);
      }

      // 線を描画
      canvas.drawLine(startPoint, endPoint, paint);

      // 矢印の描画 (変更なし)
      final Offset direction = (endPoint - startPoint);
      final double distance = direction.distance;
      final Offset normalizedDirection =
          distance == 0 ? Offset.zero : direction / distance;

      final Offset arrowPoint =
          endPoint - normalizedDirection * (isSelected ? 3 : 2);
      const double arrowSize = 6.0;
      final Path arrowPath = Path()
        ..moveTo(arrowPoint.dx, arrowPoint.dy)
        ..lineTo(
          arrowPoint.dx -
              normalizedDirection.dx * arrowSize -
              normalizedDirection.dy * arrowSize / 2,
          arrowPoint.dy -
              normalizedDirection.dy * arrowSize +
              normalizedDirection.dx * arrowSize / 2,
        )
        ..lineTo(
          arrowPoint.dx -
              normalizedDirection.dx * arrowSize +
              normalizedDirection.dy * arrowSize / 2,
          arrowPoint.dy -
              normalizedDirection.dy * arrowSize -
              normalizedDirection.dx * arrowSize / 2,
        )
        ..close();
      canvas.drawPath(arrowPath, paint..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant GsnEdgePainter oldDelegate) =>
      oldDelegate.nodes != nodes ||
      oldDelegate.edges != edges ||
      oldDelegate.connectingId != connectingId ||
      oldDelegate.isRemovalMode != isRemovalMode;
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
  // 色は白に固定し、枠線は黒に固定
  LambdaPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // 塗りつぶしは白、枠線は黒
    final paint = Paint()..color = Colors.white;
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final linePaint = Paint() // コネクタ用の太い線
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // --- 1. 定数定義と座標計算 ---
    const double wRatioTee = 0.25;
    const double wRatioTriangle = 0.10;
    const double triangleHeightRatio = 0.5; // 三角形の高さをノード全体の高さの50%に制限
    // 垂直線の長さを元の20.0pxに戻す
    final double tBarLength = size.height * 0.5;

    final double wTee = size.width * wRatioTee;
    final double wTriangle = size.width * wRatioTriangle;
    final double wOval = size.width - wTee - wTriangle;

    // 形状の開始・終了X座標
    final double xTeeEnd = wTee; // Tと三角形の境界
    final double xTriangleEnd = wTee + wTriangle; // 三角形と楕円の境界
    final double centerY = size.height / 2;

    // 三角形の高さ関連
    final double triangleBaseYTop = centerY - (size.height * triangleHeightRatio) / 2;
    final double triangleBaseYBottom = centerY + (size.height * triangleHeightRatio) / 2;

    // Tの垂直線はTコネクタ領域の中央に配置
    final double tBarX = wTee / 2;


    // --- 2. T-Connectorの描画 ---

    // (A) クロスバーを描画 (垂直線) - 長さはtBarLengthのまま
    canvas.drawLine(
      Offset(tBarX, centerY - tBarLength),
      Offset(tBarX, centerY + tBarLength),
      linePaint,
    );

    // (B) ステム (水平線) を描画: 垂直線から三角形の基部(xTeeEnd)まで接続
    // **ノード左端への突き出し (Offset(0, centerY)からOffset(tBarX, centerY)の描画)** を削除
    canvas.drawLine(
      Offset(tBarX, centerY), // Tの垂直線から
      Offset(xTeeEnd, centerY), // 三角形の基部まで
      linePaint,
    );


    // --- 3. Triangleの描画 (中央部) ---
    final trianglePath = Path()
      ..moveTo(xTeeEnd, triangleBaseYTop)
      ..lineTo(xTriangleEnd, centerY)
      ..lineTo(xTeeEnd, triangleBaseYBottom)
      ..close();

    canvas.drawPath(trianglePath, paint);
    canvas.drawPath(trianglePath, borderPaint);

    // --- 4. Ovalの描画 (右側) ---
    final ovalRect = Rect.fromLTWH(xTriangleEnd, 0, wOval, size.height);
    canvas.drawOval(ovalRect, paint);
    canvas.drawOval(ovalRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}


class ApplicationPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.0 // 線を太くする
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // --- 1. 定数定義 ---
    // ノードの約 40% を Hub コネクタ部分に割り当てる
    final double hubWidth = size.width * 0.4;
    final double centerH = size.height * 0.5;

    // --- 2. Hubのコネクタ部分 (線のみ描画) ---
    final double hubCenter = hubWidth * 0.5;

    // 縦線
    canvas.drawLine(Offset(hubCenter, 0), Offset(hubCenter, size.height), borderPaint);

    // 横線（中央の縦線から右側の三角形の境界まで）
    canvas.drawLine(Offset(hubCenter, centerH), Offset(hubWidth, centerH), borderPaint);

    // --- 3. Applicationの三角形部分 (右側 60%) ---
    final double triangleStart = hubWidth;

    final Path trianglePath = Path()
      ..moveTo(triangleStart, centerH)               // Hubコネクタの終点から開始
      ..lineTo(size.width, 0)                        // 右上の頂点
      ..lineTo(size.width, size.height)              // 右下の頂点
      ..close();

    // 三角形の塗りつぶしと枠線
    canvas.drawPath(trianglePath, fillPaint);
    canvas.drawPath(trianglePath, borderPaint);

    // 境界線が三角形に上書きされる可能性があるので、Hub線を再度描画
    canvas.drawLine(Offset(hubCenter, 0), Offset(hubCenter, size.height), borderPaint);
    canvas.drawLine(Offset(hubCenter, centerH), Offset(hubWidth, centerH), borderPaint);
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

class XPainter extends CustomPainter {
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
extension on Offset {
  Offset normalize() {
    final d = distance;
    return d == 0 ? this : this / d;

  }
}

// --- 評価結果を表示するための専用ビューア ---
class GsnResultViewer extends StatelessWidget {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;

  const GsnResultViewer({super.key, required this.nodes, required this.edges});

  @override
  Widget build(BuildContext context) {
    // キャンバスのサイズを計算（ノードがはみ出さないように）
    double maxX = 0;
    double maxY = 0;
    for (var n in nodes) {
      if (n.position.dx > maxX) maxX = n.position.dx;
      if (n.position.dy > maxY) maxY = n.position.dy;
    }
    // 余白を含めたサイズ
    final canvasWidth = max(800.0, maxX + 200);
    final canvasHeight = max(600.0, maxY + 200);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // ヘッダー
          AppBar(
            title: const Text("評価結果ビューア"),
            automaticallyImplyLeading: false,
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          // ボディ（ズーム可能なキャンバス）
          Expanded(
            child: InteractiveViewer(
              boundaryMargin: const EdgeInsets.all(double.infinity),
              minScale: 0.1,
              maxScale: 5.0,
              constrained: false, // 無限キャンバスのように振る舞う
              child: SizedBox(
                width: canvasWidth,
                height: canvasHeight,
                child: Stack(
                  children: [
                    // 1. エッジの描画
                    CustomPaint(
                      size: Size(canvasWidth, canvasHeight),
                      painter: _SimpleEdgePainter(nodes, edges),
                    ),
                    // 2. ノードの描画
                    ...nodes.map((node) {
                      return Positioned(
                        left: node.position.dx,
                        top: node.position.dy,
                        child: Container(
                          width: node.width,
                          height: node.height,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _getNodeColor(node.type), // 色分け
                            border: Border.all(color: Colors.black),
                            // ゴールなどは四角、ストラテジーは平行四辺形などが望ましいが
                            // ここでは簡易的に丸角や形状を変えるロジックを入れる
                            borderRadius: node.type == GsnNodeType.goal
                                ? BorderRadius.zero
                                : BorderRadius.circular(8),
                          ),
                          child: Text(
                            node.label,
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ノードの種類に応じた簡易的な色分け
  Color _getNodeColor(GsnNodeType type) {
    switch (type) {
      case GsnNodeType.goal: return Colors.green[100]!;
      case GsnNodeType.strategy: return Colors.grey[300]!;
      case GsnNodeType.evidence: return Colors.blue[100]!;
      case GsnNodeType.context: return Colors.yellow[100]!;
      case GsnNodeType.undeveloped: return Colors.grey;
      default: return Colors.white;
    }
  }
}

// ビューア専用のエッジ描画クラス
class _SimpleEdgePainter extends CustomPainter {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;
  _SimpleEdgePainter(this.nodes, this.edges);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (var edge in edges) {
      // IDからノードオブジェクトを検索
      try {
        final fromNode = nodes.firstWhere((n) => n.id == edge.fromId);
        final toNode = nodes.firstWhere((n) => n.id == edge.toId);

        // ノードの中心同士を結ぶ
        final start = Offset(
            fromNode.position.dx + fromNode.width / 2,
            fromNode.position.dy + fromNode.height / 2);
        final end = Offset(
            toNode.position.dx + toNode.width / 2,
            toNode.position.dy + toNode.height / 2);

        canvas.drawLine(start, end, paint);
      } catch (e) {
        // ノードが見つからない場合はスキップ
      }
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}