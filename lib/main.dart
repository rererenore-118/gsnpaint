// GSNエディタのFlutterフロントエンド（Webアプリ）。
// パレットからノードをドラッグして配置し、▶ボタンでFlaskサーバにPOSTしてPGSN評価結果をダイアログ表示する。
// エディタ状態はブラウザのSharedPreferencesに自動保存される。

import 'dart:math';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:html' as html;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'google_drive_service.dart';

void main() => runApp(const MaterialApp(
  debugShowCheckedModeBanner: false,
  home: GsnEditor(),
));

// Flaskサーバ側の gsn_type 文字列と1対1対応する（_gsnTypeName() で変換）。
// goal〜evidence がGSNの基本要素、lambda〜x がPGSN拡張のDSL要素。
enum GsnNodeType {
  goal,
  strategy,
  context,
  evidence,
  undeveloped,
  recordAccess,
  lambda,
  application,
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

  // Flaskサーバ（build_gsn.py）が期待する文字列と完全一致させる必要がある。
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
      case GsnNodeType.record:
        return 'Record';
      case GsnNodeType.recordAccess:
        return 'RecordAccess';
      case GsnNodeType.lambda:
        return 'Lambda';
      case GsnNodeType.application:
        return 'Application';
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

// エッジの向きは from（親）→ to（子）。Flaskへ送る際も同じ向きで送信する。
class GsnEdge {
  final int fromId;
  final int toId;
  GsnEdge(this.fromId, this.toId);

  factory GsnEdge.fromJson(Map<String, dynamic> json) {
    return GsnEdge(json['from'], json['to']);
  }

  Map<String, dynamic> toJson() => {'from': fromId, 'to': toId};
}

// Undo/Redo用スナップショット
class _DiagramSnapshot {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;
  final int nodeCounter;

  _DiagramSnapshot({
    required this.nodes,
    required this.edges,
    required this.nodeCounter,
  });

  factory _DiagramSnapshot.capture(
      List<GsnNode> nodes, List<GsnEdge> edges, int nodeCounter) {
    return _DiagramSnapshot(
      nodes: nodes
          .map((n) => GsnNode(
                id: n.id,
                type: n.type,
                position: n.position,
                width: n.width,
                height: n.height,
                label: n.label,
              ))
          .toList(),
      edges: edges.map((e) => GsnEdge(e.fromId, e.toId)).toList(),
      nodeCounter: nodeCounter,
    );
  }
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
  int _nodeCounter = 0; // 採番用カウンタ。削除しても減らさないため一意性が保たれる。
  bool _deleteMode = false;
  // エッジ接続の途中状態: 1回目クリックで選択したノードID。nullなら未選択。
  int? _connecting;

  // 操作履歴（元に戻す・やり直し）
  final List<_DiagramSnapshot> _undoStack = [];
  final List<_DiagramSnapshot> _redoStack = [];
  static const int _maxHistorySize = 50;

  // ドラッグ先のキャンバス領域を特定するためのキー
  final GlobalKey _dragTargetKey = GlobalKey();

  // グリッドスナップ機能
  bool _gridSnapEnabled = false;
  static const double _gridSize = 40.0;

  // 複数選択モード
  bool _selectionMode = false;
  final Set<int> _selectedNodeIds = {};
  Offset? _selectionRectStart;
  Offset? _selectionRectEnd;

  // クリップボード（コピー&ペースト用）
  List<GsnNode> _clipboard = [];
  List<GsnEdge> _clipboardEdges = [];

  // Google Drive 連携
  final GoogleDriveService _driveService = GoogleDriveService();
  bool _isDriveSignedIn = false;

  Offset _snapToGrid(Offset pos) {
    if (!_gridSnapEnabled) return pos;
    return Offset(
      (pos.dx / _gridSize).round() * _gridSize,
      (pos.dy / _gridSize).round() * _gridSize,
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedNodeIds.clear();
      _selectionRectStart = null;
      _selectionRectEnd = null;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedNodeIds.clear();
      _selectionRectStart = null;
      _selectionRectEnd = null;
    });
  }

  void _copySelected() {
    if (_selectedNodeIds.isEmpty) return;
    final selected = _nodes.where((n) => _selectedNodeIds.contains(n.id)).toList();
    _clipboard = selected
        .map((n) => GsnNode(
              id: n.id,
              type: n.type,
              position: n.position,
              width: n.width,
              height: n.height,
              label: n.label,
            ))
        .toList();
    // 選択ノード間のエッジも保持
    _clipboardEdges = _edges
        .where((e) =>
            _selectedNodeIds.contains(e.fromId) &&
            _selectedNodeIds.contains(e.toId))
        .map((e) => GsnEdge(e.fromId, e.toId))
        .toList();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${selected.length}個のノードをコピーしました')),
    );
  }

  void _pasteClipboard() {
    if (_clipboard.isEmpty) return;
    _saveToHistory();
    // 旧ID → 新IDの対応表
    final idMap = <int, int>{};
    final newNodes = <GsnNode>[];
    for (final n in _clipboard) {
      final newId = _nodeCounter++;
      idMap[n.id] = newId;
      newNodes.add(GsnNode(
        id: newId,
        type: n.type,
        position: n.position + const Offset(40, 40),
        width: n.width,
        height: n.height,
        label: n.label,
      ));
    }
    final newEdges = _clipboardEdges
        .map((e) => GsnEdge(idMap[e.fromId]!, idMap[e.toId]!))
        .toList();
    setState(() {
      _nodes.addAll(newNodes);
      _edges.addAll(newEdges);
      // ペースト後は新ノードを選択状態にする
      _selectedNodeIds
        ..clear()
        ..addAll(newNodes.map((n) => n.id));
    });
    _saveToLocalStorage();
  }

  void _deleteSelected() {
    if (_selectedNodeIds.isEmpty) return;
    _saveToHistory();
    setState(() {
      _nodes.removeWhere((n) => _selectedNodeIds.contains(n.id));
      _edges.removeWhere((e) =>
          _selectedNodeIds.contains(e.fromId) ||
          _selectedNodeIds.contains(e.toId));
      _selectedNodeIds.clear();
    });
    _saveToLocalStorage();
  }

  static const double _minW = 60;
  static const double _minH = 40;
  static const double _maxW = 800;
  static const double _maxH = 600;

  @override
  void initState() {
    super.initState();
    _loadFromLocalStorage();
    _initDrive();
  }

  /// アプリ起動時に前回のサインイン状態を静かに復元する
  Future<void> _initDrive() async {
    _driveService.onCurrentUserChanged.listen((account) {
      if (mounted) setState(() => _isDriveSignedIn = account != null);
    });
    final account = await _driveService.signInSilently();
    if (mounted) setState(() => _isDriveSignedIn = account != null);
  }

  // エディタの状態は変更せず、評価結果を別ダイアログで表示する（非破壊的）。
  // 編集中の図を上書きしないため、GsnResultViewer をダイアログとして開く設計。
  Future<void> _evaluateGsn() async {

    // 送信データ作成
    final requestData = {
      "nodes": _nodes.map((n) => {
        "id": n.id,
        "gsn_type": GsnNode._gsnTypeName(n.type),
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
      _saveToHistory();
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

  // 現在の状態をUndoスタックに保存（新しい操作前に呼ぶ）
  void _saveToHistory() {
    _undoStack.add(_DiagramSnapshot.capture(_nodes, _edges, _nodeCounter));
    if (_undoStack.length > _maxHistorySize) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_DiagramSnapshot.capture(_nodes, _edges, _nodeCounter));
    final snap = _undoStack.removeLast();
    _applySnapshot(snap);
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_DiagramSnapshot.capture(_nodes, _edges, _nodeCounter));
    final snap = _redoStack.removeLast();
    _applySnapshot(snap);
  }

  void _applySnapshot(_DiagramSnapshot snap) {
    setState(() {
      _nodes.clear();
      _nodes.addAll(snap.nodes);
      _edges.clear();
      _edges.addAll(snap.edges);
      _nodeCounter = snap.nodeCounter;
      _connecting = null;
    });
    _saveToLocalStorage();
  }

  void _addNode(GsnNodeType type, Offset position) {
    _saveToHistory();
    setState(() {
      _nodes.add(GsnNode(
        id: _nodeCounter++,
        type: type,
        position: _snapToGrid(position),
        label: (type == GsnNodeType.record ||
                              type == GsnNodeType.x ||
                              type == GsnNodeType.undeveloped)
                              ? null
                              : "",
      ));
    });
    _saveToLocalStorage();
  }

  void _toggleDeleteMode() {
    setState(() => _deleteMode = !_deleteMode);
  }

  // 2タップでエッジ接続: 1回目でfrom（青くなる）を選択、2回目でtoを確定してエッジ追加。
  // 同じノードを2回タップするとキャンセル。
  void _handleTapNode(GsnNode node) {
    if (_deleteMode) {
      _confirmDeleteNode(node);
    } else {
      if (_connecting == null) {
        setState(() => _connecting = node.id);
      } else if (_connecting != node.id) {
        _saveToHistory();
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
              _saveToHistory();
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
              _saveToHistory();
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
          _saveToHistory();
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
            icon: const Icon(Icons.undo),
            onPressed: _undoStack.isEmpty ? null : _undo,
            tooltip: '元に戻す (Undo)',
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            onPressed: _redoStack.isEmpty ? null : _redo,
            tooltip: 'やり直す (Redo)',
          ),
          IconButton(
            icon: Icon(
              _gridSnapEnabled ? Icons.grid_on : Icons.grid_off,
              color: _gridSnapEnabled ? Colors.blue : null,
            ),
            onPressed: () => setState(() => _gridSnapEnabled = !_gridSnapEnabled),
            tooltip: 'グリッドスナップ切替',
          ),
          IconButton(
            icon: Icon(
              Icons.select_all,
              color: _selectionMode ? Colors.orange : null,
            ),
            onPressed: _toggleSelectionMode,
            tooltip: '複数選択モード切替',
          ),
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: _selectedNodeIds.isNotEmpty ? _copySelected : null,
              tooltip: '選択ノードをコピー',
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _selectedNodeIds.isNotEmpty ? _deleteSelected : null,
              tooltip: '選択ノードを一括削除',
            ),
            IconButton(
              icon: const Icon(Icons.paste),
              onPressed: _clipboard.isNotEmpty ? _pasteClipboard : null,
              tooltip: 'ペースト (+40px オフセット)',
            ),
          ],
          IconButton(
            icon: Icon(
                _deleteMode ? Icons.delete_forever : Icons.delete_outline),
            onPressed: _toggleDeleteMode,
            tooltip: '削除モード切替',
          ),
          IconButton(
              onPressed: _exportJson,
              icon: const Icon(Icons.save_alt),
              tooltip: 'JSON保存（ローカル）'),
           IconButton(
              onPressed: _evaluateGsn,
              icon: const Icon(Icons.play_arrow), // アイコンを再生マークに変更
              tooltip: 'サーバーで評価'),
          // ローカルファイルから読み込むボタン
          IconButton(
            onPressed: _importJson,
            icon: const Icon(Icons.folder_open),
            tooltip: 'ローカルJSON読み込み',
          ),
          // Google Drive 連携ボタン群
          IconButton(
            icon: Icon(
              _isDriveSignedIn ? Icons.account_circle : Icons.account_circle_outlined,
              color: _isDriveSignedIn ? Colors.green : null,
            ),
            onPressed: _toggleDriveSignIn,
            tooltip: _isDriveSignedIn
                ? 'Googleサインアウト（${_driveService.currentUser?.email ?? ""}）'
                : 'Googleサインイン',
          ),
          if (_isDriveSignedIn) ...[
            IconButton(
              icon: const Icon(Icons.cloud_upload),
              onPressed: _saveToDrive,
              tooltip: 'Driveに保存',
            ),
            IconButton(
              icon: const Icon(Icons.cloud_download),
              onPressed: _loadFromDrive,
              tooltip: 'Driveから読み込み',
            ),
          ],
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '図をすべて削除（リセット）',
            onPressed: _confirmClearDiagram, // <-- 新しいメソッドを呼び出す
          ),
        ],
      ),
      body: Row(
        children: [
          const SingleChildScrollView(
            child: GsnPalette(),
          ),
          Expanded(
            child: DragTarget<GsnNodeType>(
              key: _dragTargetKey,
              builder: (context, candidateData, rejectedData) {
                return GestureDetector(
                onTapDown: (e) {
                  final sceneP = _tc.toScene(e.localPosition);
                  if (_selectionMode) {
                    // 選択解除はonTapで行う（onTapDownはドラッグ開始時にも発火するため）
                  } else if (_deleteMode) {
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
                onTap: () {
                  // 選択モード中に空白部分をタップしたら選択解除
                  // (ノード上のタップはノード側のGestureDetectorが勝つためここには来ない)
                  if (_selectionMode) {
                    _clearSelection();
                  }
                },
                onPanStart: !_selectionMode ? null : (d) {
                  setState(() {
                    _selectionRectStart = _tc.toScene(d.localPosition);
                    _selectionRectEnd = _tc.toScene(d.localPosition);
                  });
                },
                onPanUpdate: !_selectionMode ? null : (d) {
                  setState(() {
                    _selectionRectEnd = _tc.toScene(d.localPosition);
                  });
                },
                onPanEnd: !_selectionMode ? null : (d) {
                  if (_selectionRectStart != null && _selectionRectEnd != null) {
                    final rect = Rect.fromPoints(_selectionRectStart!, _selectionRectEnd!);
                    setState(() {
                      for (final n in _nodes) {
                        final nodeRect = Rect.fromLTWH(
                            n.position.dx, n.position.dy, n.width, n.height);
                        if (rect.overlaps(nodeRect)) {
                          _selectedNodeIds.add(n.id);
                        }
                      }
                      _selectionRectStart = null;
                      _selectionRectEnd = null;
                    });
                  }
                },
                child: InteractiveViewer(
                  transformationController: _tc,
                  minScale: 0.25,
                  maxScale: 4,
                  panEnabled: !_selectionMode,
                  scaleEnabled: true,
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(2000),
                  child: SizedBox(
                    width: _worldSize.width,
                    height: _worldSize.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        if (_gridSnapEnabled)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: GridPainter(gridSize: _gridSize),
                            ),
                          ),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: GsnEdgePainter(_nodes, _edges,
                                connectingId: _connecting),
                          ),
                        ),
                        if (_selectionMode &&
                            _selectionRectStart != null &&
                            _selectionRectEnd != null)
                          Positioned(
                            left: min(_selectionRectStart!.dx, _selectionRectEnd!.dx),
                            top: min(_selectionRectStart!.dy, _selectionRectEnd!.dy),
                            child: IgnorePointer(
                              child: Container(
                                width: (_selectionRectStart!.dx - _selectionRectEnd!.dx).abs(),
                                height: (_selectionRectStart!.dy - _selectionRectEnd!.dy).abs(),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Colors.blue.withOpacity(0.8),
                                      width: 1.5),
                                  color: Colors.blue.withOpacity(0.1),
                                ),
                              ),
                            ),
                          ),
                        ..._nodes.map((node) {
                          final isConnecting = _connecting == node.id;
                          return Positioned(
                            left: node.position.dx,
                            top: node.position.dy,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                if (_selectionMode) {
                                  setState(() {
                                    if (_selectedNodeIds.contains(node.id)) {
                                      _selectedNodeIds.remove(node.id);
                                    } else {
                                      _selectedNodeIds.add(node.id);
                                    }
                                  });
                                } else {
                                  _handleTapNode(node);
                                }
                              },
                              onPanStart: (_) => _saveToHistory(),
                              onPanUpdate: (d) {
                                final scale = _tc.value.getMaxScaleOnAxis();
                                setState(() {
                                  if (_selectionMode &&
                                      _selectedNodeIds.contains(node.id)) {
                                    // 選択中の全ノードを一括移動
                                    for (final n in _nodes) {
                                      if (_selectedNodeIds.contains(n.id)) {
                                        n.position = _snapToGrid(
                                            n.position + d.delta / scale);
                                      }
                                    }
                                  } else {
                                    node.position = _snapToGrid(
                                        node.position + d.delta / scale);
                                  }
                                });
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
                                  // 選択ハイライト
                                  if (_selectionMode &&
                                      _selectedNodeIds.contains(node.id))
                                    Positioned(
                                      left: -3,
                                      top: -3,
                                      child: IgnorePointer(
                                        child: Container(
                                          width: node.width + 6,
                                          height: node.height + 6,
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                                color: Colors.orange,
                                                width: 3),
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                        ),
                                      ),
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
                                      onDragStart: () => _saveToHistory(),
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
              // details.offset はグローバル座標のため、
              // DragTarget のローカル座標に変換してから toScene() に渡す
              final renderBox = _dragTargetKey.currentContext!
                  .findRenderObject()! as RenderBox;
              final localOffset = renderBox.globalToLocal(details.offset);
              final scenePosition = _tc.toScene(localOffset);
              _addNode(details.data, scenePosition);
            },
          ),
        ),
        ],
      ),
    );
  }

  // エッジをクリックしたかを判定する。エッジはfrom下辺中央→to上辺中央の直線として近似し、10px以内をヒットとする。
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
        _saveToHistory();
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

  // ---- Google Drive 連携 ----

  /// サインイン／サインアウトを切り替える
  Future<void> _toggleDriveSignIn() async {
    try {
      if (_isDriveSignedIn) {
        await _driveService.signOut();
        if (mounted) {
          setState(() => _isDriveSignedIn = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Google ドライブからサインアウトしました。')),
          );
        }
      } else {
        final account = await _driveService.signIn();
        if (mounted) {
          if (account != null) {
            setState(() => _isDriveSignedIn = true);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${account.email} でサインインしました。')),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('サインインがキャンセルされました。')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラー: $e')),
        );
      }
    }
  }

  /// 保存ダイアログを表示して Google Drive に保存する
  Future<void> _saveToDrive() async {
    if (!_isDriveSignedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先にGoogleアカウントでサインインしてください。')),
      );
      return;
    }

    // フォルダ一覧を取得
    List<DriveItem> folders = [];
    try {
      folders = await _driveService.listFolders();
    } catch (_) {}

    if (!mounted) return;

    // 保存ダイアログを表示
    final result = await showDialog<_DriveSaveParams>(
      context: context,
      builder: (ctx) => _DriveSaveDialog(folders: folders),
    );
    if (result == null) return; // キャンセル

    try {
      final data = {
        'nodes': _nodes.map((n) => n.toJson()).toList(),
        'edges': _edges.map((e) => e.toJson()).toList(),
        'nodeCounter': _nodeCounter,
      };
      final jsonString = const JsonEncoder.withIndent('  ').convert(data);
      await _driveService.saveFile(
        jsonString,
        result.fileName,
        folderId: result.folderId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${result.fileName}.json」を Google ドライブに保存しました。')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗しました: $e')),
        );
      }
    }
  }

  /// ファイル一覧ダイアログを表示して Google Drive から読み込む
  Future<void> _loadFromDrive() async {
    if (!_isDriveSignedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先にGoogleアカウントでサインインしてください。')),
      );
      return;
    }

    // ファイル一覧を取得（マイドライブ全体から検索）
    List<DriveItem> files = [];
    try {
      files = await _driveService.listJsonFiles();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ファイル一覧の取得に失敗しました: $e')),
        );
      }
      return;
    }

    if (!mounted) return;

    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google ドライブに JSON ファイルが見つかりませんでした。')),
      );
      return;
    }

    // ファイル選択ダイアログを表示
    final selected = await showDialog<DriveItem>(
      context: context,
      builder: (ctx) => _DriveLoadDialog(files: files),
    );
    if (selected == null) return; // キャンセル

    try {
      final jsonString = await _driveService.loadFileById(selected.id);
      final data = jsonDecode(jsonString);
      _saveToHistory();
      setState(() {
        _nodes.clear();
        _edges.clear();
        _nodes.addAll((data['nodes'] as List).map((n) => GsnNode.fromJson(n)));
        _edges.addAll((data['edges'] as List).map((e) => GsnEdge.fromJson(e)));
        _nodeCounter = data['nodeCounter'] ?? 0;
      });
      _saveToLocalStorage();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${selected.name}」を読み込みました。')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込みに失敗しました: $e')),
        );
      }
    }
  }
}

// ---- Drive 保存ダイアログ ----

class _DriveSaveParams {
  final String fileName;
  final String folderId;
  const _DriveSaveParams({required this.fileName, required this.folderId});
}

class _DriveSaveDialog extends StatefulWidget {
  final List<DriveItem> folders;
  const _DriveSaveDialog({required this.folders});

  @override
  State<_DriveSaveDialog> createState() => _DriveSaveDialogState();
}

class _DriveSaveDialogState extends State<_DriveSaveDialog> {
  final _nameController = TextEditingController(text: 'gsn');
  String _selectedFolderId = 'root';

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Drive に保存'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ファイル名'),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Text('.json', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('保存先フォルダ'),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _selectedFolderId,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(
                  value: 'root',
                  child: Text('マイドライブ（ルート）'),
                ),
                ...widget.folders.map((f) => DropdownMenuItem(
                      value: f.id,
                      child: Text(f.name),
                    )),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _selectedFolderId = v;
                });
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              _DriveSaveParams(
                fileName: name,
                folderId: _selectedFolderId,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ---- Drive 読み込みダイアログ ----

class _DriveLoadDialog extends StatelessWidget {
  final List<DriveItem> files;
  const _DriveLoadDialog({required this.files});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Drive から読み込む'),
      content: SizedBox(
        width: 400,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: files.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (ctx, i) {
            final f = files[i];
            final modified = f.modifiedTime != null
                ? f.modifiedTime!.substring(0, 10)
                : '';
            return ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: Text(f.name),
              subtitle: modified.isNotEmpty ? Text('更新: $modified') : null,
              onTap: () => Navigator.pop(context, f),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
      ],
    );
  }
}


// ノードタイプ別の形状ウィジェットを返す。
// Application/Mapはキャンバス上ではラベルを非表示にする（図形の形だけで型が識別できるため）。
Widget _buildGsnShapeWidget(GsnNode node, {bool isPalette = false}) {
  final labelStyle = TextStyle(
    fontSize: isPalette ? 10 : 12,
    fontWeight: FontWeight.bold,
    color: node.type == GsnNodeType.map ? Colors.white : Colors.black,
  );

  final label = Center(
    child: Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text(
        node.label,
        textAlign: TextAlign.center,
        style: labelStyle,
        softWrap: true,
        overflow: TextOverflow.clip,
        maxLines: isPalette ? 2 : null,
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
    case GsnNodeType.record:
      return buildPainter(RecordPainter());
    case GsnNodeType.lambda:
      // ラベルを楕円内部に描画するため CustomPaint に直接渡す
      return CustomPaint(
        size: Size(node.width, node.height),
        painter: LambdaPainter(label: node.label),
      );
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
      return buildPainter(StringLiteralPainter());
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

  // パレットの表示順とグループ定義
  static const _groups = [
    _PaletteGroup(
      label: 'GSN',
      types: [
        GsnNodeType.goal,
        GsnNodeType.strategy,
        GsnNodeType.context,
        GsnNodeType.evidence,
        GsnNodeType.undeveloped,
      ],
    ),
    _PaletteGroup(
      label: 'λ 計算',
      types: [
        GsnNodeType.lambda,
        GsnNodeType.application,
        GsnNodeType.map,
        GsnNodeType.x,
      ],
    ),
    _PaletteGroup(
      label: 'レコード',
      types: [
        GsnNodeType.record,
        GsnNodeType.recordLabel,
        GsnNodeType.recordAccess,
        GsnNodeType.stringLiteral,
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final group in _groups) ...[
              // セクションヘッダー
              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 2.0),
                child: Text(
                  group.label,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.black54,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const Divider(height: 4, thickness: 1),
              // グループ内のノード
              for (final type in group.types) _PaletteItem(type: type),
            ],
          ],
        ),
      ),
    );
  }
}

// パレットのグループ定義クラス
class _PaletteGroup {
  final String label;
  final List<GsnNodeType> types;
  const _PaletteGroup({required this.label, required this.types});
}

class _PaletteItem extends StatelessWidget {
  final GsnNodeType type;
  const _PaletteItem({required this.type});

  @override
  Widget build(BuildContext context) {
    final nodeForShape = GsnNode(
      id: -1,
      type: type,
      position: Offset.zero,
      width: 80,
      height: 48,
      label: "",
    );
    final nodeForFeedback = GsnNode(
      id: -1,
      type: type,
      position: Offset.zero,
      width: 80,
      height: 48,
      label: GsnNode._gsnTypeName(type),
    );

    // 図形ウィジェットの生成
    final shapeWidget = _buildGsnShapeWidget(nodeForShape, isPalette: true);
    final feedbackWidget = _buildGsnShapeWidget(nodeForFeedback, isPalette: true);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Draggable<GsnNodeType>(
        data: type,
        // ドラッグ中の見た目（半透明の図形の中に文字）
        feedback: Material(
          elevation: 4.0,
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.7,
            child: feedbackWidget,
          ),
        ),
        // ▼▼▼ パレット上の見た目（図形の下に文字を表示） ▼▼▼
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 図形部分（文字なし）
            shapeWidget,
            const SizedBox(height: 4), // 図形と文字の間隔
            // 文字部分
            Text(
              GsnNode._gsnTypeName(type),
              style: const TextStyle(
                fontSize: 11,
                color: Colors.black87,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  final VoidCallback? onDragStart;
  final void Function(double dx, double dy) onDrag;
  final VoidCallback onDragEnd;
  const _ResizeHandle({this.onDragStart, required this.onDrag, required this.onDragEnd});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => onDragStart?.call(),
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

class GridPainter extends CustomPainter {
  final double gridSize;

  GridPainter({required this.gridSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.withOpacity(0.25)
      ..strokeWidth = 0.5;

    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) =>
      oldDelegate.gridSize != gridSize;
}

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
  // 補助: Application/Map ノードの接続点を「役割」で決定する
  //   nodeIsFrom == true  → このノードが送り出し側（from）
  //   nodeIsFrom == false → このノードが受け取り側（to）
  // ----------------------------------------------------
  static const _callableTypes = {
    GsnNodeType.lambda,
    GsnNodeType.application,
    GsnNodeType.x,
    GsnNodeType.map,
  };

  // RecordLabel / RecordAccess は中央の縦線を接続点とするノード。
  // 常に topCenter（上端の線上）/ bottomCenter（下端の線上）で繋ぐ。
  static bool _usesLineCenterConnection(GsnNode node) =>
      node.type == GsnNodeType.recordLabel ||
      node.type == GsnNodeType.recordAccess;

  Offset _getAppOrMapPoint(
      GsnNode node, Rect rect, GsnNode otherNode, bool nodeIsFrom) {
    const double hubRatio = 0.4;
    const double hubCenterRatio = hubRatio * 0.5;

    // Application は縦線のX座標、Map はノード中央のX座標を使う
    final double lineX = node.type == GsnNodeType.application
        ? rect.left + node.width * hubCenterRatio
        : rect.center.dx;

    final topPoint    = Offset(lineX, rect.top);
    final bottomPoint = Offset(lineX, rect.bottom);
    final rightPoint  = Offset(rect.right, rect.center.dy);

    if (!nodeIsFrom) {
      // 受け取り側（親から繋がれる）→ 常に上
      return topPoint;
    }
    // 送り出し側: 相手が callable なら下、それ以外（引数）なら右
    return _callableTypes.contains(otherNode.type) ? bottomPoint : rightPoint;
  }

  // ----------------------------------------------------
  // 補助: 特殊ノード（Lambda/Application/Map）の接続候補点リストを取得する
  // ----------------------------------------------------
  List<Offset> _getSpecialPoints(GsnNode node, Rect rect) {
    if (node.type == GsnNodeType.lambda) {
      // Lambdaノードの接続点: 左側Tコネクタの上端・下端
      const double wRatioTee = 0.25;
      final double wTee = node.width * wRatioTee;
      final double tBarX = rect.left + wTee / 2;

      final specialTop = Offset(tBarX, rect.top);
      final specialBottom = Offset(tBarX, rect.bottom);
      return [specialTop, specialBottom];
    } else if (node.type == GsnNodeType.application) {
      // Applicationノードの接続点: 縦線の上端・下端・右端
      const double hubRatio = 0.4;
      const double hubCenterRatio = hubRatio * 0.5;
      final double lineX = rect.left + node.width * hubCenterRatio;

      final specialTop = Offset(lineX, rect.top);
      final specialBottom = Offset(lineX, rect.bottom);
      final specialRight = Offset(rect.right, rect.center.dy);
      return [specialTop, specialBottom, specialRight];
    } else if (node.type == GsnNodeType.map) {
      // Mapノードの接続点: 中央の黒い四角形の上端・下端・右端
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
  // 描画処理の本体: 全エッジを走査して線を引く
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

Offset startPoint = Offset.zero;
Offset endPoint   = Offset.zero;
// Map引数用L字接続の折れ点（null = 直線で描画）
Offset? _bend1;
Offset? _bend2;

      // 特殊ノード判定
      final bool fromIsLambda = fromNode.type == GsnNodeType.lambda;
      final bool toIsLambda = toNode.type == GsnNodeType.lambda;
      final bool fromIsApplication = fromNode.type == GsnNodeType.application;
      final bool toIsApplication = toNode.type == GsnNodeType.application;
      final bool fromIsMap = fromNode.type == GsnNodeType.map;
      final bool toIsMap = toNode.type == GsnNodeType.map;
      final bool fromIsSpecial = fromIsLambda || fromIsApplication || fromIsMap;
      final bool toIsSpecial = toIsLambda || toIsApplication || toIsMap;

      final bool fromIsRecordLabel = fromNode.type == GsnNodeType.recordLabel;
      final bool toIsRecordLabel = fromNode.type == GsnNodeType.recordLabel;
      final bool fromIsRecordAccess = fromNode.type == GsnNodeType.recordAccess;
      final bool toIsRecordAccess = fromNode.type == GsnNodeType.recordAccess;

      final bool fromIsLiteral = fromIsRecordLabel || fromIsRecordAccess;
      final bool toIsLiteral = toIsRecordLabel || fromIsRecordAccess;





      // ----------------------------------------------------
      // ケース1・2: 両方のノードが特殊ノード（Lambda/Application/Map）の場合
      // ----------------------------------------------------
      if (fromIsSpecial && toIsSpecial) {
          final fromRect = Rect.fromLTWH(fromNode.position.dx, fromNode.position.dy, fromNode.width, fromNode.height);
          final toRect   = Rect.fromLTWH(toNode.position.dx,   toNode.position.dy,   toNode.width,   toNode.height);

          // Application/Map が絡む場合: 役割（送り出し/受け取り）で接続点を決める
          if (fromIsApplication || fromIsMap) {
            startPoint = _getAppOrMapPoint(fromNode, fromRect, toNode, true);
          }
          if (toIsApplication || toIsMap) {
            endPoint = _getAppOrMapPoint(toNode, toRect, fromNode, false);
          }

          // Lambda 同士など Application/Map が絡まない場合: 最短距離で接続点を決める
          if (!fromIsApplication && !fromIsMap && !toIsApplication && !toIsMap) {
            final fromPoints = _getSpecialPoints(fromNode, fromRect);
            final toPoints   = _getSpecialPoints(toNode,   toRect);
            double minDist = double.infinity;
            startPoint = fromPoints.first;
            endPoint   = toPoints.first;
            for (final p1 in fromPoints) {
              for (final p2 in toPoints) {
                final d = (p1 - p2).distanceSquared;
                if (d < minDist) { minDist = d; startPoint = p1; endPoint = p2; }
              }
            }
          } else {
            // 役割ベースで片方が確定している場合、もう片方を距離で補完
            if (!fromIsApplication && !fromIsMap) {
              final fromPoints = _getSpecialPoints(fromNode, fromRect);
              startPoint = fromPoints.reduce((a, b) =>
                  (a - endPoint).distanceSquared < (b - endPoint).distanceSquared ? a : b);
            }
            if (!toIsApplication && !toIsMap) {
              final toPoints = _getSpecialPoints(toNode, toRect);
              endPoint = toPoints.reduce((a, b) =>
                  (a - startPoint).distanceSquared < (b - startPoint).distanceSquared ? a : b);
            }
          }

      } else if (fromIsSpecial || toIsSpecial) {

          // ----------------------------------------------------
          // ケース3: 片方のみが特殊ノードの場合
          // ----------------------------------------------------
          final fromRect = Rect.fromLTWH(fromNode.position.dx, fromNode.position.dy, fromNode.width, fromNode.height);
          final toRect   = Rect.fromLTWH(toNode.position.dx,   toNode.position.dy,   toNode.width,   toNode.height);

          if (fromIsApplication || fromIsMap) {
            // Application/Map が送り出し側（from） → 役割で接続点を決める
            startPoint = _getAppOrMapPoint(fromNode, fromRect, toNode, true);
            // RecordLabel/RecordAccess は中央線（topCenter）で受け取る
            if (_usesLineCenterConnection(toNode)) {
              endPoint = toRect.topCenter;
            // Map の引数（右端から伸びる）→ L字折れ線で引数の上辺中央へ
            } else if (fromIsMap &&
                !_callableTypes.contains(toNode.type) &&
                startPoint.dx >= fromRect.center.dx) {
              endPoint = toRect.topCenter;
              // 折れ点: Map右端と同じy、引数のcenter.dxの真上で折れて垂直に下りる
              _bend1 = Offset(toRect.center.dx, startPoint.dy);
              _bend2 = null; // 折れ点は1つだけ（水平→垂直の2セグメント）
            } else {
              endPoint = _getNearestPointOnRect(toRect, startPoint);
            }
          } else if (toIsApplication || toIsMap) {
            // Application/Map が受け取り側（to） → 役割で接続点を決める
            endPoint   = _getAppOrMapPoint(toNode, toRect, fromNode, false);
            // RecordLabel/RecordAccess は中央線（bottomCenter）から送り出す
            startPoint = _usesLineCenterConnection(fromNode)
                ? fromRect.bottomCenter
                : _getNearestPointOnRect(fromRect, endPoint);
          } else {
            // Lambda が特殊ノード → 最短距離で接続点を決める
            GsnNode specialNode = fromIsLambda ? fromNode : toNode;
            GsnNode otherNode   = fromIsLambda ? toNode   : fromNode;
            final specialRect   = fromIsLambda ? fromRect : toRect;
            final otherRect     = fromIsLambda ? toRect   : fromRect;

            final points = _getSpecialPoints(specialNode, specialRect);
            final closestPt = points.reduce((a, b) =>
                (a - otherRect.center).distanceSquared <
                        (b - otherRect.center).distanceSquared
                    ? a
                    : b);

            if (specialNode == fromNode) {
              startPoint = closestPt;
              endPoint   = _getNearestPointOnRect(otherRect, closestPt);
            } else {
              startPoint = _getNearestPointOnRect(otherRect, closestPt);
              endPoint   = closestPt;
            }
          }

      } else {
          // ----------------------------------------------------
          // ケース4: 通常ノード同士の接続（GSN要素など）
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



          // Context / Assumption は横からエッジを繋ぐ
          // Contextがfromノードより右にあれば右辺→左辺、左なら左辺→右辺
          final toIsContext = toNode.type == GsnNodeType.context;
          final fromIsContext = fromNode.type == GsnNodeType.context;

          if (toIsContext || fromIsContext) {
            // どちらがContextかを判断して、横方向に接続する
            final contextRect  = toIsContext ? toRect   : fromRect;
            final goalRect     = toIsContext ? fromRect : toRect;

            // ContextがGoalより右にあるか左にあるかで接続辺を決める
            if (contextRect.center.dx >= goalRect.center.dx) {
              // Contextが右側 → Goalの右辺 → Contextの左辺
              startPoint = toIsContext ? goalRect.centerRight    : contextRect.centerRight;
              endPoint   = toIsContext ? contextRect.centerLeft  : goalRect.centerLeft;
            } else {
              // Contextが左側 → Goalの左辺 → Contextの右辺
              startPoint = toIsContext ? goalRect.centerLeft     : contextRect.centerLeft;
              endPoint   = toIsContext ? contextRect.centerRight : goalRect.centerRight;
            }
          } else {
            // スタート地点：fromNodeの真ん中下
            startPoint = fromRect.bottomCenter;

            // エンド地点：toNodeの真ん中上
            endPoint = toRect.topCenter;
          }
      }


      // 線を描画（Map引数はL字折れ線、それ以外は直線）
      if (_bend1 != null) {
        // L字折れ線: startPoint → bend1 → (bend2 →) endPoint
        final path = Path()
          ..moveTo(startPoint.dx, startPoint.dy)
          ..lineTo(_bend1!.dx, _bend1!.dy);
        if (_bend2 != null) path.lineTo(_bend2!.dx, _bend2!.dy);
        path.lineTo(endPoint.dx, endPoint.dy);
        canvas.drawPath(path, paint..style = PaintingStyle.stroke);
      } else {
        canvas.drawLine(startPoint, endPoint, paint);
      }

      // 矢印の向きは最後のセグメントの方向で決める
      final Offset arrowFrom = _bend2 ?? _bend1 ?? startPoint;
      final Offset direction = (endPoint - arrowFrom);
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

// 文字(String)ノード用のPainter
class StringLiteralPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 背景を薄い黄色にしてデータっぽさを出す
    final fillPaint = Paint()..color = Colors.yellow.shade100;
    // 枠線はオレンジ色
    final borderPaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRect(rect, fillPaint);
    canvas.drawRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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


class LambdaPainter extends CustomPainter {
  final String label;
  LambdaPainter({required this.label});

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
    final double tBarLength = size.height * 0.5;

    final double wTee = size.width * wRatioTee;
    final double wTriangle = size.width * wRatioTriangle;
    final double wOval = size.width - wTee - wTriangle;

    // 形状の開始・終了X座標
    final double xTeeEnd = wTee;        // Tと三角形の境界
    final double xTriangleEnd = wTee + wTriangle; // 三角形と楕円の境界
    final double centerY = size.height / 2;

    // 三角形の高さ関連
    final double triangleBaseYTop    = centerY - (size.height * triangleHeightRatio) / 2;
    final double triangleBaseYBottom = centerY + (size.height * triangleHeightRatio) / 2;

    // Tの垂直線はTコネクタ領域の中央に配置
    final double tBarX = wTee / 2;

    // --- 2. T-Connectorの描画 ---
    // (A) クロスバー（垂直線）
    canvas.drawLine(
      Offset(tBarX, centerY - tBarLength),
      Offset(tBarX, centerY + tBarLength),
      linePaint,
    );
    // (B) ステム（水平線）: 垂直線から三角形の基部まで
    canvas.drawLine(
      Offset(tBarX, centerY),
      Offset(xTeeEnd, centerY),
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

    // --- 5. 楕円内にラベルテキストを描画 ---
    if (label.isNotEmpty) {
      const double padding = 8.0;
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 3,
        ellipsis: '...',
      );
      // 楕円の幅からパディングを引いた範囲でレイアウト
      textPainter.layout(maxWidth: wOval - padding * 2);
      // 楕円の中央に配置
      final textX = xTriangleEnd + (wOval - textPainter.width) / 2;
      final textY = (size.height - textPainter.height) / 2;
      textPainter.paint(canvas, Offset(textX, textY));
    }
  }

  @override
  bool shouldRepaint(covariant LambdaPainter oldDelegate) =>
      oldDelegate.label != label;
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

  //  canvas.drawLine(Offset(size.width * 0.5, 0), Offset(size.width*0.5, rect.top), linePaint);
  //  canvas.drawLine(Offset(size.width * 0.5, rect.bottom), Offset(size.width*0.5, size.height), linePaint);
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
    // 1. 白い塗りつぶしの設定
    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    // 2. 黒い枠線の設定
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // 3. 六角形の形（パス）を作る
    final path = Path();
    // 左右の尖り具合（幅の15%くらいを尖らせる）
    final double offset = size.width * 0.15;

    path.moveTo(offset, 0);                        // 左上
    path.lineTo(size.width - offset, 0);           // 右上
    path.lineTo(size.width, size.height / 2);      // 右端（尖っている部分）
    path.lineTo(size.width - offset, size.height); // 右下
    path.lineTo(offset, size.height);              // 左下
    path.lineTo(0, size.height / 2);               // 左端（尖っている部分）
    path.close();                                  // パスを閉じる

    // 4. 描画実行
    canvas.drawPath(path, fillPaint);   // 白で塗る
    canvas.drawPath(path, borderPaint); // 黒で枠線を書く
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

// 評価結果を読み取り専用で表示するダイアログ。エディタの _nodes/_edges は変更しない。
class GsnResultViewer extends StatelessWidget {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;

  const GsnResultViewer({super.key, required this.nodes, required this.edges});

  @override
  Widget build(BuildContext context) {
    // キャンバスのサイズ計算
    double maxX = 0;
    double maxY = 0;
    for (var n in nodes) {
      if (n.position.dx > maxX) maxX = n.position.dx;
      if (n.position.dy > maxY) maxY = n.position.dy;
    }
    // ノードの幅なども考慮して少し余裕を持たせる
    final canvasWidth = max(800.0, maxX + 200);
    final canvasHeight = max(600.0, maxY + 200);

    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: Column(
        children: [
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
          Expanded(
            child: InteractiveViewer(
              boundaryMargin: const EdgeInsets.all(double.infinity),
              minScale: 0.1,
              maxScale: 5.0,
              constrained: false,
              child: SizedBox(
                width: canvasWidth,
                height: canvasHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // エッジの描画
                    CustomPaint(
                      size: Size(canvasWidth, canvasHeight),
                      painter: _SimpleEdgePainter(nodes, edges),
                    ),
                    // ノードの描画
                    ...nodes.map((node) {
                      return Positioned(
                        left: node.position.dx,
                        top: node.position.dy,
                        // ★修正点: エディタ本体と同じ描画関数を再利用する
                        // これにより、Strategyは平行四辺形、Evidenceは楕円など、
                        // エディタと全く同じ見た目で表示されます。
                        child: _buildGsnShapeWidget(node),
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
}



  // ▼▼▼ 色の定義を編集画面（各Painter）に合わせる ▼▼▼
  Color _getNodeColor(GsnNodeType type) {
    switch (type) {
      case GsnNodeType.goal:
        return Colors.lightBlue.shade100; // 編集画面のGoal色
      case GsnNodeType.strategy:
        return Colors.orangeAccent.shade100; // 編集画面のStrategy色
      case GsnNodeType.context:
        return Colors.purple.shade100; // 編集画面のContext色
      case GsnNodeType.map:
        return Colors.black; // 編集画面のMap色
      case GsnNodeType.evidence:
      case GsnNodeType.undeveloped:
      case GsnNodeType.record:
      case GsnNodeType.lambda:
      case GsnNodeType.application:
      default:
        return Colors.white; // その他は基本白
    }
  }

  // ▼▼▼ ノードの形状定義（Evidenceを楕円にする） ▼▼▼
  ShapeBorder _getNodeShape(GsnNodeType type) {
    if (type == GsnNodeType.evidence) {
      // Evidenceは楕円形
      return const OvalBorder(side: BorderSide(color: Colors.black));
    }
    // その他は角丸四角形または四角形
    // GoalとMapは角を丸めない、Context等は丸める
    double radius = 8.0;
    if (type == GsnNodeType.goal || type == GsnNodeType.map) {
      radius = 0.0;
    } else if (type == GsnNodeType.context) {
      radius = 12.0;
    }

    return RoundedRectangleBorder(
      side: const BorderSide(color: Colors.black),
      borderRadius: BorderRadius.circular(radius),
    );
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