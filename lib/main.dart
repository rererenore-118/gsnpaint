// GSNエディタのFlutterフロントエンド（Webアプリ）。
// パレットからノードをドラッグして配置し、▶ボタンでFlaskサーバにPOSTしてPGSN評価結果をダイアログ表示する。
// エディタ状態はブラウザのSharedPreferencesに自動保存される。

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:html' as html;
// dart:typed_data は package:flutter/services.dart が再エクスポートするため不要
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseFirestore;
import 'firebase_options.dart';
import 'account_dialog.dart';
import 'cloud_diagram_dialogs.dart';
import 'cloud_diagram_service.dart';
import 'cloud_csv_service.dart';

// PDF出力（評価前の編集中の図・評価結果の図の両方で使う）
part 'pdf_export.dart';

// 評価サーバ（Flask）のURL。手元のサーバで試すときは
// --dart-define=API_BASE=http://127.0.0.1:5000 を付けて起動する。
const String _apiBase =
    String.fromEnvironment('API_BASE', defaultValue: 'https://pgsn-api.onrender.com');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ★追加(接続キャンセル): 右クリックを「接続のキャンセル」に割り当てるため、
  // ブラウザ標準のコンテキストメニューを止める。
  BrowserContextMenu.disableContextMenu();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // 開発時の動作確認用: --dart-define=USE_FIREBASE_EMULATOR=true で起動したときだけ、
  // 本物の Firebase ではなくローカルのエミュレータ（firebase emulators:start）につなぐ。
  if (const bool.fromEnvironment('USE_FIREBASE_EMULATOR')) {
    await FirebaseAuth.instance.useAuthEmulator('localhost', 9099);
    FirebaseFirestore.instance.useFirestoreEmulator('localhost', 8080);
  }
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GsnEditor(),
  ));
}

// Flaskサーバ側の gsn_type 文字列と1対1対応する（_gsnTypeName() で変換）。
// goal〜evidence がGSNの基本要素、lambda〜x がPGSN拡張のDSL要素。
enum GsnNodeType {
  goal,
  strategy,
  context,
  evidence,
  undeveloped,
  assumption,
  justification,
  defeater, // ★追加: Confidence Argument対応。GSNノードへの疑義(反論)を表すノード
            // （PGSN v0.0.4以降はGoal/Strategy/Evidence/Defeaterのどれにも付けられる）
  recordAccess,
  lambda,
  application,
  map,
  stringLiteral,
  recordLabel,
  record,
  x,
  fileList,
}

// Context/Assumption/JustificationはGSN標準のInContextOf関係を持つ要素で、
// いずれも親ノードの横に配置し、横方向にエッジを繋ぐ（レイアウト・描画の両方で共用）。
// これらは葉ノード（自身はさらに子を持たない）という前提で共用している。
const Set<GsnNodeType> _sideAttachedTypes = {
  GsnNodeType.context,
  GsnNodeType.assumption,
  GsnNodeType.justification,
};

// ★追加(Defeater): Defeaterは「親の横に付く」点はContext等と同じだが、
// 自分自身の下に反論への応答(Rebuttal)チェーンを展開できる点が異なるため、
// レイアウト計算では区別できるよう専用セットを用意する。
// - _expandableSideTypes: 「横に付くが、自分の下にも子を展開する」ノード
// - _allSideTypes: レイアウト上「親の横バケット」に振り分けるノード全体（既存の副作用を避けるため
//   エッジ描画の横方向判定(_sideAttachedTypes)はこれまで通り据え置き、Defeaterはそちらに含めない）
const Set<GsnNodeType> _expandableSideTypes = {
  GsnNodeType.defeater,
};
const Set<GsnNodeType> _allSideTypes = {
  ..._sideAttachedTypes,
  ..._expandableSideTypes,
};

// ★追加(Dialectic): GSN v3のDialectic拡張における"challenges"関係。
// SupportedBy/InContextOfとは別の第三の関係性として、エッジの終点(to)がDefeaterであることから判定する
// （エッジ自体にrelation種別を保存するのではなく、ノード種別から導出する。値が常に一致し不整合が起きないため）。
bool _isChallengesEdge(GsnNode toNode) => toNode.type == GsnNodeType.defeater;

// ★追加(Dialectic): 破線を描画する共通ヘルパー。"challenges"エッジとinDoubt状態のDefeaterの枠線に使う。
void _drawDashedPath(Canvas canvas, Path path, Paint paint,
    {double dashWidth = 5, double dashGap = 4}) {
  for (final metric in path.computeMetrics()) {
    double distance = 0;
    while (distance < metric.length) {
      final len = min(dashWidth, metric.length - distance);
      canvas.drawPath(metric.extractPath(distance, distance + len), paint);
      distance += dashWidth + dashGap;
    }
  }
}

// ★追加(Dialectic): DefeaterがGSN v3の言うdefeated(有効な裏付けあり)かinDoubt(未対応)かを判定する。
// 「未開発(Undeveloped)なGoal的主張による疑義はinDoubt、実際の裏付け(Evidence等)を伴う主張はdefeated」
// という区別に対応：子(=Defeater自身の主張を支える内容)がUndeveloped以外の形で存在すればdefeated。
// ★変更(PGSN v0.0.4): Defeater自身にもDefeaterが付く（反証への反証）ようになった。
// 子のDefeaterは「支え(support)」ではなく「このDefeaterへの疑義」なので、裏付けとは数えない。
bool _isDefeaterBacked(
    GsnNode defeaterNode, List<GsnNode> allNodes, List<GsnEdge> edges) {
  final nodeMap = {for (final n in allNodes) n.id: n};
  for (final e in edges) {
    if (e.fromId != defeaterNode.id) continue;
    final child = nodeMap[e.toId];
    if (child != null &&
        child.type != GsnNodeType.undeveloped &&
        child.type != GsnNodeType.defeater) {
      return true;
    }
  }
  return false;
}

class GsnNode {
  final int id;
  final GsnNodeType type;
  Offset position;
  double width;
  double height;
  String label;
  // ★追加(PGSN v0.0.4): 支持(support)が未展開であることを示す印。評価結果にだけ付く。
  // GSN規格どおり、独立したノードではなくこのノードの下辺に小さな菱形として描く。
  final bool undeveloped;

  GsnNode({
    required this.id,
    required this.type,
    required this.position,
    this.width = 100,
    this.height = 60,
    String? label,
    this.undeveloped = false,
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
      undeveloped: json['undeveloped'] == true,
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
        if (undeveloped) 'undeveloped': true,
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
      case GsnNodeType.assumption:
        return 'Assumption';
      case GsnNodeType.justification:
        return 'Justification';
      case GsnNodeType.defeater: // ★追加(Defeater)
        return 'Defeater';
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
      case GsnNodeType.fileList:
        return 'FileList';
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
                undeveloped: n.undeveloped,
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
  // ★追加(接続プレビュー): 接続待ちのあいだカーソルを追う線の終点（シーン座標）。
  // setStateではなくValueNotifierで保持し、プレビュー線のレイヤーだけを塗り直す
  // （マウスを動かすたびに図全体をrebuildすると、ノードが増えたときに重くなるため）。
  final ValueNotifier<Offset?> _connectPreviewEnd = ValueNotifier<Offset?>(null);

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

  // ★追加(折りたたみ): 折りたたまれているノードのID集合。
  // ここに入っているノードの子孫(横付け要素も含む)は非表示になる。
  // セッション内だけの表示状態として扱い、保存/読み込みの対象にはしない
  // （読み込んだ図は常に全展開の状態で始まる方が分かりやすいため）。
  final Set<int> _collapsedNodeIds = {};
  // ★追加(折りたたみ): onTapDownで捉えたローカル座標を、直後のonTapで折りたたみバッジの
  // 当たり判定に使うための一時保存（onTapは引数なしのため）。onTapを従来通りのシグネチャのまま
  // 維持し、位置情報だけonTapDownで追加取得する形にして、ジェスチャー認識の挙動を変えないようにする。
  Offset? _lastTapDownLocalPos;
  // ★追加(折りたたみ): バッジの描画サイズと当たり判定を1箇所で管理する
  // （両者がずれると「見えている場所を押しても反応しない」という状態になるため）。
  static const double _collapseBadgeInset = 2.0; // ノード左上からのオフセット
  static const double _collapseBadgeSize = 22.0; // 描画される円の直径
  // 当たり判定はノードの角(0,0)から、バッジの右下端 + 余白まで。押しやすさのため実際の円より広めに取る。
  static const double _collapseBadgeHitArea =
      _collapseBadgeInset + _collapseBadgeSize + 6.0;

  // エディタのアカウント（Firebase Authentication）。null ならログインしていない。
  // 図やCSVのクラウド保存（Firestore）に使う。
  User? _user;
  StreamSubscription<User?>? _authSub;

  // アカウント（Firestore）への図の保存・読み出し
  final CloudDiagramService _cloudService = CloudDiagramService();
  // アカウント（Firestore）に置くCSV。FileListノードが参照する
  final CloudCsvService _csvService = CloudCsvService();
  // 直前に保存・読み込みした図の名前。次の保存ダイアログの初期値にする。
  String _cloudDiagramName = 'gsn';

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

  // ★追加(折りたたみ): from→childrenのマップを作る共通ヘルパー（_autoLayout内のものと同じ考え方）
  Map<int, List<int>> _buildChildrenMap() {
    final map = <int, List<int>>{for (final n in _nodes) n.id: []};
    for (final e in _edges) {
      map[e.fromId]?.add(e.toId);
    }
    return map;
  }

  // ★追加(折りたたみ): _collapsedNodeIdsに基づき、非表示にすべきノードID集合を計算する。
  // 畳んだノードの子孫(横付け要素含む)を再帰的にすべて辿る。
  Set<int> _computeHiddenNodeIds() {
    if (_collapsedNodeIds.isEmpty) return const {};
    final childrenMap = _buildChildrenMap();
    final hidden = <int>{};
    void hideDescendants(int nid) {
      for (final cid in childrenMap[nid] ?? []) {
        if (hidden.add(cid)) hideDescendants(cid);
      }
    }
    for (final cid in _collapsedNodeIds) {
      hideDescendants(cid);
    }
    return hidden;
  }

  // ★追加(折りたたみ): 指定ノード配下の子孫の総数（折りたたみ時のバッジ表示用）
  int _countDescendants(int nodeId) {
    final childrenMap = _buildChildrenMap();
    final seen = <int>{};
    void visit(int nid) {
      for (final cid in childrenMap[nid] ?? []) {
        if (seen.add(cid)) visit(cid);
      }
    }
    visit(nodeId);
    return seen.length;
  }

  // ★追加(折りたたみ): 折りたたみ状態をトグルする。レイアウトの保存対象ではないため
  // _saveToLocalStorage()は呼ばない（表示だけの一時的な状態のため）。
  void _toggleCollapse(int nodeId) {
    setState(() {
      if (_collapsedNodeIds.contains(nodeId)) {
        _collapsedNodeIds.remove(nodeId);
      } else {
        _collapsedNodeIds.add(nodeId);
      }
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
    _clearLocalStorage();
    // ログイン状態は Firebase がブラウザに保持しており、再読み込み後も自動で復元されて通知が来る
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (mounted) {
        setState(() {
          // 別のアカウントに切り替わったら、前のアカウントの図の名前は引き継がない
          if (user?.uid != _user?.uid) _cloudDiagramName = 'gsn';
          _user = user;
        });
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _connectPreviewEnd.dispose();
    super.dispose();
  }

  Future<void> _clearLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('gsn_editor_data');
  }

  // エディタの状態は変更せず、評価結果を別ダイアログで表示する（非破壊的）。
  // 編集中の図を上書きしないため、GsnResultViewer をダイアログとして開く設計。
  Future<void> _evaluateGsn() async {

    // 送信データ作成
    final Map<String, Object> requestData = {
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

    // FileListノードが使うCSVは、アカウントから中身を読んで図と一緒に送る
    // （評価サーバはCSVを保存しないため）。
    final csvNames = _nodes
        .where((n) => n.type == GsnNodeType.fileList)
        .map((n) => n.label.trim())
        .toSet();
    if (csvNames.isNotEmpty) {
      if (_user == null) {
        _showErrorDialog('CSVファイルを使う図の評価にはログインが必要です。');
        return;
      }
      try {
        final contents = await _csvService.loadContents(csvNames);
        final missing = csvNames.where((n) => !contents.containsKey(n)).toList();
        if (missing.isNotEmpty) {
          _showErrorDialog('次のCSVファイルがアカウントにありません。'
              'アップロードしてから評価してください。\n${missing.join('\n')}');
          return;
        }
        requestData["csv_files"] = contents;
      } catch (e) {
        _showErrorDialog('CSVファイルの読み込みに失敗しました: $e');
        return;
      }
    }

    try {
      // サーバーへ送信
      final response = await http.post(
        Uri.parse('$_apiBase/evaluate'),
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

  void _autoLayout() {
    if (_nodes.isEmpty) return;
    _saveToHistory();

    const double xGap = 20.0;
    const double ySpacing = 160.0;
    const double margin = 50.0;
    const double ctxSideGap = 40.0;

    final nodeMap = {for (final n in _nodes) n.id: n};

    // 子リスト構築
    final childrenMap = <int, List<int>>{for (final n in _nodes) n.id: []};
    final hasParent = <int>{};
    for (final e in _edges) {
      childrenMap[e.fromId]?.add(e.toId);
      hasParent.add(e.toId);
    }

    // ★追加(折りたたみ): 畳まれているノードは、以降のレイアウト計算では
    // 子を持たない葉ノードとして扱う（隠れているのに裏でスペースを確保し続けるのを防ぐ）。
    for (final cid in _collapsedNodeIds) {
      childrenMap[cid] = [];
    }

    final roots = _nodes.where((n) => !hasParent.contains(n.id)).map((n) => n.id).toList();

    List<int> ctxSplit(int nid, bool left) {
      // ★変更(Defeater): 従来はContext等(_sideAttachedTypes)のみを横バケットに振り分けていたが、
      // Defeaterも「親の横に付く」点は同じなので_allSideTypesで判定する。
      final ctxChildren = (childrenMap[nid] ?? [])
          .where((c) => _allSideTypes.contains(nodeMap[c]?.type))
          .toList();
      final half = ctxChildren.length ~/ 2;
      return left ? ctxChildren.sublist(0, half) : ctxChildren.sublist(half);
    }

    // ★追加(PGSN v0.0.4): 横付けノードが横方向に占める幅。Defeater自身にもDefeater（反証への反証）が
    // 付き得るので、その分を外側へ再帰的に足す。
    double sideWidth(int cid) {
      var w = nodeMap[cid]!.width;
      if (_expandableSideTypes.contains(nodeMap[cid]!.type)) {
        final nested = (childrenMap[cid] ?? [])
            .where((c) => _allSideTypes.contains(nodeMap[c]?.type))
            .toList();
        if (nested.isNotEmpty) {
          w += ctxSideGap + nested.map(sideWidth).reduce((a, b) => a > b ? a : b);
        }
      }
      return w;
    }

    // ★既知の制限: Defeaterの下に展開される反論(Rebuttal)チェーンがDefeater本体より横に広い場合、
    // その分は幅計算に反映されない（入れ子のDefeaterによる横方向の広がりはsideWidthで反映する）。
    double ctxExtraLeft(int nid) {
      final leftCtxs = ctxSplit(nid, true);
      if (leftCtxs.isEmpty) return 0.0;
      return (leftCtxs.map(sideWidth).reduce((a, b) => a > b ? a : b)) + ctxSideGap;
    }

    double ctxExtraRight(int nid) {
      final rightCtxs = ctxSplit(nid, false);
      if (rightCtxs.isEmpty) return 0.0;
      return (rightCtxs.map(sideWidth).reduce((a, b) => a > b ? a : b)) + ctxSideGap;
    }

    // ★変更(重なり修正): 以前は「サブツリー幅」という単一の値で持ち、base領域が中心から左右対称に
    // 広がる前提で計算していた。しかし子が1つのとき（縦揃えのため）子の本体中心を親の中心に合わせると、
    // 子の横付け要素が片側にしか無い場合にbase領域は左右非対称になる。この非対称を単一の幅で表せず、
    // 「親が確保したつもりの右端」より実際の子サブツリーが右にはみ出し、
    // 親自身の横付け要素（Defeaterとその反論チェーン）と衝突していた。
    // そこで中心からの張り出しを左右別々(baseHalfLeft/baseHalfRight)に保持する。
    final baseHalfLeft = <int, double>{};
    final baseHalfRight = <int, double>{};

    // サブツリー全体の幅（横付け要素も含む）。兄弟を横に並べる際の間隔計算に使う。
    double subtreeWidth(int nid) =>
        ctxExtraLeft(nid) + baseHalfLeft[nid]! + baseHalfRight[nid]! + ctxExtraRight(nid);

    void computeExtents(int nid) {
      if (baseHalfLeft.containsKey(nid)) return;
      final nonCtx = (childrenMap[nid] ?? [])
          .where((c) => !_allSideTypes.contains(nodeMap[c]?.type))
          .toList();
      final halfW = nodeMap[nid]!.width / 2;
      double hl, hr;
      if (nonCtx.isEmpty) {
        hl = hr = halfW;
      } else if (nonCtx.length == 1) {
        // 子が1つ: 子の本体中心を親の中心に合わせるため、張り出しは子の張り出しをそのまま引き継ぐ
        final c = nonCtx.first;
        computeExtents(c);
        final l = baseHalfLeft[c]! + ctxExtraLeft(c);
        final r = baseHalfRight[c]! + ctxExtraRight(c);
        hl = halfW > l ? halfW : l;
        hr = halfW > r ? halfW : r;
      } else {
        // 子が複数: 横並びの総幅を中心に振り分けるので左右対称になる
        for (final c in nonCtx) {
          computeExtents(c);
        }
        final total = nonCtx.fold(0.0, (sum, c) => sum + subtreeWidth(c)) +
            xGap * (nonCtx.length - 1);
        hl = hr = halfW > total / 2 ? halfW : total / 2;
      }
      baseHalfLeft[nid] = hl;
      baseHalfRight[nid] = hr;
    }

    for (final n in _nodes) {
      computeExtents(n.id);
    }

    final placedNodes = <int>{};

    const mapFunctionTypes = {GsnNodeType.lambda, GsnNodeType.application, GsnNodeType.x};

    // ★追加(Defeater): placeChildrenBelow()とplace()は互いを呼び合う（相互再帰）ため、
    // Dartのローカル関数は前方参照できない制約を回避するべく、先にplaceを変数として宣言しておく。
    // ★変更(重なり修正): 第2引数は「サブツリーの左端」ではなく「ノード本体の中心X」。
    late void Function(int nid, double centerX, int depth) place;

    // ★追加(Defeater): 「中心線centerXの下に、通常の子ノード群を横並びの中央揃えで展開する」処理。
    // 通常のGoal直下の子だけでなく、Defeater自身の下に伸びる反論(Rebuttal)チェーンにも使い回す。
    void placeChildrenBelow(int parentNid, double centerX, int childDepth) {
      final children = (childrenMap[parentNid] ?? [])
          .where((c) => !_allSideTypes.contains(nodeMap[c]?.type))
          .toList();
      if (children.isEmpty) return;

      // 子が1つだけの場合、その子の本体中心を親の中心にそのまま合わせる（Goal/Strategyの縦揃え）。
      if (children.length == 1) {
        final cid = children.first;
        if (!placedNodes.contains(cid)) {
          placedNodes.add(cid);
          place(cid, centerX, childDepth);
        }
        return;
      }

      // 子が複数: サブツリー幅の合計を親の中心に振り分けて横並びにする
      final childrenTotal = children.fold(0.0, (sum, c) => sum + subtreeWidth(c)) +
          xGap * (children.length - 1);
      double cursor = centerX - childrenTotal / 2;
      for (final cid in children) {
        if (!placedNodes.contains(cid)) {
          placedNodes.add(cid);
          // cursorはサブツリーの左端。そこから左側の横付け要素分と本体の左張り出し分を進めた位置が本体中心。
          place(cid, cursor + ctxExtraLeft(cid) + baseHalfLeft[cid]!, childDepth);
        }
        cursor += subtreeWidth(cid) + xGap;
      }
    }

    // edgeXの外側（toLeftなら左、そうでなければ右）へ横付けノードを縦に積む。
    // Defeaterは横に付けた上で、その真下に反論(Rebuttal)チェーンを中央揃えで展開し、
    // ★追加(PGSN v0.0.4): 反証への反証（入れ子のDefeater）を同じ向きのさらに外側へ付ける。
    void placeSideNodes(List<int> sideIds, double edgeX, double topY, int depth, bool toLeft) {
      for (int i = 0; i < sideIds.length; i++) {
        final cid = sideIds[i];
        placedNodes.add(cid);
        final cn = nodeMap[cid]!;
        cn.position = Offset(
            toLeft ? edgeX - ctxSideGap - cn.width : edgeX + ctxSideGap,
            topY + i * (cn.height + 10));
        if (_expandableSideTypes.contains(cn.type)) {
          placeChildrenBelow(cid, cn.position.dx + cn.width / 2, depth + 1);
          final outerEdge = toLeft ? cn.position.dx : cn.position.dx + cn.width;
          placeSideNodes(ctxSplit(cid, true) + ctxSplit(cid, false), outerEdge,
              cn.position.dy, depth, toLeft);
        }
      }
    }

    place = (int nid, double baseCenter, int depth) {
      final node = nodeMap[nid]!;

      // 接続点がbaseCenterに揃うようノード種別ごとにオフセットを調整
      // Lambda: T字バー(left+width*0.125)、Application: 縦線(left+width*0.2)、その他: 中央
      const double lambdaTBarRatio = 0.125;
      const double appLineRatio = 0.2;
      final double nodeOffsetX = node.type == GsnNodeType.lambda
          ? node.width * lambdaTBarRatio
          : node.type == GsnNodeType.application
              ? node.width * appLineRatio
              : node.width / 2;
      node.position = Offset(baseCenter - nodeOffsetX, margin + depth * ySpacing);

      // Map/Applicationノード：関数子を接続点直下、引数子を関数子の右に横並び
      if (node.type == GsnNodeType.map || node.type == GsnNodeType.application) {
        final allChildren = childrenMap[nid] ?? [];
        final funcChildren = allChildren.where((c) => mapFunctionTypes.contains(nodeMap[c]?.type)).toList();
        final argChildren = allChildren.where((c) => !mapFunctionTypes.contains(nodeMap[c]?.type)).toList();

        final childY = margin + (depth + 1) * ySpacing;

        // 接続点のX座標: Map/Application共にbaseCenter（各ノードはposition調整済み）
        final double funcX = baseCenter;

        for (final cid in funcChildren) {
          if (!placedNodes.contains(cid)) {
            placedNodes.add(cid);
            final cn = nodeMap[cid]!;
            final offsetX = cn.type == GsnNodeType.lambda
                ? cn.width * lambdaTBarRatio
                : cn.type == GsnNodeType.application
                    ? cn.width * appLineRatio
                    : cn.width / 2;
            // ★変更(重なり修正): place()は中心X基準になったのでfuncXをそのまま渡す
            // （直後にcn.positionを上書きするので、この呼び出しは主に子孫を配置するためのもの）
            place(cid, funcX, depth + 1);
            cn.position = Offset(funcX - offsetX, childY);
          }
        }

        // 引数子を関数子の右に横並び（実際の右端から開始）
        double argX;
        if (funcChildren.isEmpty) {
          argX = funcX + xGap;
        } else {
          final fcn = nodeMap[funcChildren.first]!;
          final fOffsetX = fcn.type == GsnNodeType.lambda
              ? fcn.width * lambdaTBarRatio
              : fcn.type == GsnNodeType.application
                  ? fcn.width * appLineRatio
                  : fcn.width / 2;
          argX = (funcX - fOffsetX) + fcn.width + xGap;
        }
        for (final cid in argChildren) {
          if (!placedNodes.contains(cid)) {
            placedNodes.add(cid);
            final cn = nodeMap[cid]!;
            cn.position = Offset(argX, childY);
            argX += cn.width + xGap;
          }
        }
        return;
      }

      // ★変更(Defeater): 直書きだったループをplaceChildrenBelow()呼び出しに置き換え（挙動は従来と同一）
      placeChildrenBelow(nid, baseCenter, depth + 1);

      // ★変更(重なり修正): 横付け要素は「ノード自身の箱」ではなく「本体+その子孫が実際に占める領域」の
      // 外側に置く。左右の張り出しは非対称になりうるので、baseHalfLeft/baseHalfRightを使う。
      final contentLeftEdge = baseCenter - baseHalfLeft[nid]!;
      final contentRightEdge = baseCenter + baseHalfRight[nid]!;

      placeSideNodes(ctxSplit(nid, true), contentLeftEdge, node.position.dy, depth, true);
      placeSideNodes(ctxSplit(nid, false), contentRightEdge, node.position.dy, depth, false);
    };

    // GoalノードのルートをPGSNノードより先に配置する
    const gsnRootTypes = {GsnNodeType.goal};
    final sortedRoots = [
      ...roots.where((id) => gsnRootTypes.contains(nodeMap[id]!.type)),
      ...roots.where((id) => !gsnRootTypes.contains(nodeMap[id]!.type)),
    ];

    void placeSafe(int nid, double centerX, int depth) {
      if (placedNodes.contains(nid)) return;
      placedNodes.add(nid);
      place(nid, centerX, depth);
    }

    // ★変更(重なり修正): cursorは各ルートのサブツリー左端。place()には本体中心を渡す。
    double cursor = margin;
    for (final rid in sortedRoots) {
      placeSafe(rid, cursor + ctxExtraLeft(rid) + baseHalfLeft[rid]!, 0);
      cursor += subtreeWidth(rid) + xGap * 2;
    }

    // 負座標補正
    if (_nodes.isNotEmpty) {
      final minX = _nodes.map((n) => n.position.dx).reduce((a, b) => a < b ? a : b);
      if (minX < margin) {
        final shift = margin - minX;
        for (final n in _nodes) {
          n.position = Offset(n.position.dx + shift, n.position.dy);
        }
      }
    }

    setState(() {});
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

  // ★追加(接続キャンセル): 接続待ちを解除する。Esc・右クリック・空白クリックから呼ぶ。
  void _cancelConnecting() {
    if (_connecting == null) return;
    setState(() => _connecting = null);
    _connectPreviewEnd.value = null;
  }

  // 2タップでエッジ接続: 1回目でfrom（青くなる）を選択、2回目でtoを確定してエッジ追加。
  // 同じノードを2回タップするとキャンセル。
  // 接続待ちの解除はここ（同じノードを再タップ）のほか、Esc・右クリック・空白クリックでも行える。
  void _handleTapNode(GsnNode node) {
    if (_deleteMode) {
      _confirmDeleteNode(node);
    } else {
      if (_connecting == null) {
        setState(() => _connecting = node.id);
        // ★追加(接続プレビュー): 最初のホバーを待たずに線が出るよう、押した位置を初期値にする
        // （_lastTapDownLocalPos はノードローカル座標なので、位置を足してシーン座標に直す）。
        _connectPreviewEnd.value = node.position +
            (_lastTapDownLocalPos ?? Offset(node.width / 2, node.height / 2));
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
    // ★追加(接続キャンセル): Escキーで接続待ちを解除する。
    // ラベル編集などのダイアログは別ルートなので、開いている間はそちらがキーを受け取る
    // （Escでダイアログが閉じる従来の挙動は変わらない）。
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _connecting != null) {
          _cancelConnecting();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
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
              onPressed: _nodes.isEmpty ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf),
              tooltip: 'PDF保存（現在の図）'),
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
          // エディタのアカウント（ログイン/ログアウト）
          IconButton(
            icon: Icon(
              _user != null ? Icons.person : Icons.person_outline,
              color: _user != null ? Colors.blue : null,
            ),
            onPressed: _openAccount,
            tooltip: _user != null
                ? 'アカウント（${_user!.email ?? ""}）'
                : 'ログイン / 新規登録',
          ),
          if (_user != null) ...[
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveToCloud,
              tooltip: 'アカウントに保存',
            ),
            IconButton(
              icon: const Icon(Icons.folder_special),
              onPressed: _openFromCloud,
              tooltip: 'アカウントから開く',
            ),
          ],
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'CSVをアカウントにアップロード',
            onPressed: _uploadCsv,
          ),
          IconButton(
            icon: const Icon(Icons.account_tree),
            tooltip: '自動レイアウト',
            onPressed: _nodes.isEmpty ? null : _autoLayout,
          ),
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: '図をすべて削除（リセット）',
            onPressed: _confirmClearDiagram,
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
                  } else if (_hitTestAnyNode(sceneP)) {
                    // ★変更(エッジ接続): ノード上のタップはノード側のGestureDetectorに任せ、
                    // ここでは何もしない。以前はこの位置で無条件に _connecting = null して
                    // いたが、キャンバス側のonTapDownは押下が kPressTimeout(100ms) を超えると
                    // ジェスチャーアリーナの決着を待たずに発火する。そのため2ノード目を
                    // ゆっくり押すと、ノードのonTapが走る前に接続待ち状態が消え、エッジが
                    // 張られずにそのノードが新しい始点になってしまっていた
                    // （素早くクリックしたときだけ繋がる、という症状）。
                  } else if (_connecting != null) {
                    // 空白部分のタップは接続のキャンセル
                    _cancelConnecting();
                  } else {
                    // ★変更(誤削除の防止): ノード上のタップではエッジ削除の判定をしない。
                    // 詳細は _hitTestAnyNode() のコメントを参照。
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
                // ★追加(接続キャンセル): 右クリックで接続待ちを解除する。
                // ノード側のGestureDetectorには副ボタンのハンドラを置いていないので、
                // ノードの上で右クリックしてもこちらが拾う（どちらでもキャンセルしたいため）。
                onSecondaryTap: _cancelConnecting,
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
                  child: Builder(builder: (context) {
                    // ★追加(折りたたみ): 畳まれたノードの子孫を非表示にする
                    final hiddenIds = _computeHiddenNodeIds();
                    final visibleNodes =
                        _nodes.where((n) => !hiddenIds.contains(n.id)).toList();
                    final visibleEdges = _edges
                        .where((e) =>
                            !hiddenIds.contains(e.fromId) &&
                            !hiddenIds.contains(e.toId))
                        .toList();
                    return MouseRegion(
                      // ★追加(接続プレビュー): 接続待ちのあいだ、カーソルを追う線を描くために
                      // ホバー座標を拾う。InteractiveViewerの内側に置いているので
                      // localPosition はすでにシーン座標（図そのものの座標系）になっている。
                      onHover: (e) {
                        if (_connecting == null) return;
                        _connectPreviewEnd.value = e.localPosition;
                      },
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
                            painter: GsnEdgePainter(_nodes, visibleEdges,
                                connectingId: _connecting),
                          ),
                        ),
                        // ★追加(接続プレビュー): 始点ノードからカーソルへ破線を描く層。
                        // 「次にクリックしたノードが終点になる」ことを見て分かるようにする。
                        // IgnorePointerで当たり判定には一切影響させない。
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: ConnectingPreviewPainter(
                                nodes: visibleNodes,
                                fromId: _connecting,
                                cursor: _connectPreviewEnd,
                              ),
                            ),
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
                        ...visibleNodes.map((node) {
                          final isConnecting = _connecting == node.id;
                          return Positioned(
                            left: node.position.dx,
                            top: node.position.dy,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // ★変更(折りたたみ): 折りたたみバッジは独立したGestureDetectorとしては
                              // 実装しない（このノード本体のGestureDetectorに onPanStart/onPanUpdate が
                              // 同居しており、入れ子のGestureDetectorではジェスチャーアリーナで
                              // タップがpan側に取られてバッジのタップが拾えなかったため）。
                              // onTapのシグネチャ自体は変えず、onTapDownで座標だけ先に拾っておく。
                              onTapDown: (details) =>
                                  _lastTapDownLocalPos = details.localPosition,
                              onTap: () {
                                final pos = _lastTapDownLocalPos;
                                final hasChildren =
                                    _edges.any((e) => e.fromId == node.id);
                                if (pos != null &&
                                    hasChildren &&
                                    pos.dx >= 0 &&
                                    pos.dx <= _collapseBadgeHitArea &&
                                    pos.dy >= 0 &&
                                    pos.dy <= _collapseBadgeHitArea) {
                                  _toggleCollapse(node.id);
                                  return;
                                }
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
                                  _buildGsnShapeWidget(
                                    node,
                                    // ★追加(Dialectic): DefeaterがdefeatedかinDoubtかを表示に反映する
                                    defeaterBacked:
                                        node.type == GsnNodeType.defeater
                                            ? _isDefeaterBacked(
                                                node, _nodes, _edges)
                                            : false,
                                  ),
                                  // ★追加(折りたたみ): 子を持つノードにだけ、折りたたみ用のバッジを表示する。
                                  // このバッジ自体はIgnorePointerにして独自のヒットテストを持たせない
                                  // （タップ判定はノード本体のGestureDetector側のonTapで座標判定している。
                                  // 理由は上のonTapDown/onTap側のコメントを参照）。
                                  // 位置とサイズは_collapseBadge*定数で判定領域と揃える。
                                  if (_edges.any((e) => e.fromId == node.id))
                                    Positioned(
                                      left: _collapseBadgeInset,
                                      top: _collapseBadgeInset,
                                      child: IgnorePointer(
                                        child: Container(
                                          width: _collapseBadgeSize,
                                          height: _collapseBadgeSize,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white,
                                            border: Border.all(
                                                color: Colors.black54),
                                          ),
                                          alignment: Alignment.center,
                                          child:
                                              _collapsedNodeIds.contains(node.id)
                                                  ? Text(
                                                      '+${_countDescendants(node.id)}',
                                                      style: const TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color:
                                                              Colors.black87),
                                                    )
                                                  : const Icon(Icons.remove,
                                                      size: 12,
                                                      color: Colors.black87),
                                        ),
                                      ),
                                    ),
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
                    );
                  }),
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
              if (details.data == GsnNodeType.fileList) {
                _addFileListNode(scenePosition);
              } else {
                _addNode(details.data, scenePosition);
              }
            },
          ),
        ),
        ],
      ),
      ),
    );
  }

  // ★追加(誤削除の防止): 指定座標がいずれかの「表示中の」ノードの矩形内にあるかを判定する。
  // キャンバス側のonTapDownはジェスチャーアリーナの決着前に発火するため、ノード上をタップしても
  // 必ず一度は発火してしまう（onTapと違い「子が勝つから来ない」が成立しない）。
  // そのためエッジ削除の判定前にこれで弾き、ノード上のタップ（折りたたみバッジ含む）が
  // 誤ってエッジ削除を引き起こさないようにする。
  bool _hitTestAnyNode(Offset p) {
    final hiddenIds = _computeHiddenNodeIds();
    for (final n in _nodes) {
      if (hiddenIds.contains(n.id)) continue;
      final rect =
          Rect.fromLTWH(n.position.dx, n.position.dy, n.width, n.height);
      // 折りたたみバッジやリサイズハンドルはノード矩形の外側にもわずかにはみ出すため、
      // 少し広げた範囲を「ノード上」とみなす。
      if (rect.inflate(10).contains(p)) return true;
    }
    return false;
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


  /// CSVを選んでアカウント（Firestore）に保存する。同じ名前のCSVがあれば上書きを確認する。
  Future<void> _uploadCsv() async {
    if (_user == null) {
      _showResultDialog('ログインが必要です', 'CSVのアップロードにはログインしてください。');
      return;
    }

    final input = html.FileUploadInputElement()..accept = '.csv';
    input.click();

    input.onChange.listen((e) async {
      final files = input.files;
      if (files == null || files.isEmpty) return;

      final file = files[0];
      final reader = html.FileReader();

      reader.onLoadEnd.listen((e) async {
        // 評価サーバは UTF-8 として読むため、それ以外（Excel の Shift_JIS 保存など）はここで弾く
        final String content;
        try {
          content = utf8
              .decode(reader.result as List<int>)
              .replaceFirst('\uFEFF', ''); // BOM付きUTF-8も受け付ける
        } on FormatException {
          _showResultDialog('アップロード失敗',
              'CSVの文字コードが UTF-8 ではありません。\n'
              'Excel の場合は「CSV UTF-8（コンマ区切り）」で保存し直してください。');
          return;
        }

        try {
          if (await _csvService.exists(file.name)) {
            if (!mounted) return;
            final overwrite = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('上書きの確認'),
                content: Text('「${file.name}」はすでにアカウントにあります。上書きしますか？'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('キャンセル')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('上書き')),
                ],
              ),
            );
            if (overwrite != true) return;
          }

          await _csvService.save(file.name, content);
          final preview = const LineSplitter().convert(content).take(5).join('\n');
          _showResultDialog('アップロード完了: ${file.name}', '先頭5行:\n$preview');
        } catch (err) {
          _showResultDialog('アップロード失敗', '$err');
        }
      });

      reader.readAsArrayBuffer(file);
    });
  }

  /// アカウントのCSVから1つ選んで FileList ノードを置く
  Future<void> _addFileListNode(Offset position) async {
    if (_user == null) {
      _showResultDialog('ログインが必要です', 'CSVファイルを使うにはログインしてください。');
      return;
    }
    try {
      final files = await _csvService.listNames();

      if (!mounted) return;

      if (files.isEmpty) {
        _showResultDialog('CSVファイルなし', 'まずCSVをアカウントにアップロードしてください。');
        return;
      }

      String? selected = files.first;

      await showDialog(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('CSVファイルを選択'),
            content: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              items: files
                  .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                  .toList(),
              onChanged: (v) => setDialogState(() => selected = v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _nodes.add(GsnNode(
                      id: _nodeCounter++,
                      type: GsnNodeType.fileList,
                      position: position,
                      label: selected!,
                    ));
                  });
                  _saveToLocalStorage();
                },
                child: const Text('追加'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      _showResultDialog('エラー', 'CSVファイルの一覧を取得できませんでした。\n$e');
    }
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

  // 編集中の図（評価前）をPDFに書き出す。
  // 折りたたみ中のノードは画面に出ていないため、出力からも除く（見えている図＝出力）。
  Future<void> _exportPdf() async {
    final hiddenIds = _computeHiddenNodeIds();
    final visibleNodes =
        _nodes.where((n) => !hiddenIds.contains(n.id)).toList();
    final visibleEdges = _edges
        .where((e) =>
            !hiddenIds.contains(e.fromId) && !hiddenIds.contains(e.toId))
        .toList();

    try {
      await _exportDiagramPdf(
        nodes: visibleNodes,
        edges: visibleEdges,
        edgePainter: GsnEdgePainter(visibleNodes, visibleEdges),
        fileName: 'gsn.pdf',
      );
    } catch (e) {
      if (mounted) _showPdfErrorDialog(context, e);
    }
  }

  /// アカウントボタン: 未ログインならログインダイアログ、ログイン中ならアカウント情報とログアウト
  Future<void> _openAccount() async {
    final user = _user;
    if (user == null) {
      final signedIn = await showDialog<bool>(
        context: context,
        builder: (ctx) => const AccountDialog(),
      );
      if (signedIn == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${FirebaseAuth.instance.currentUser?.email ?? ""} でログインしました。')),
        );
      }
      return;
    }

    final signOut = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アカウント'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ログイン中のアカウント'),
            const SizedBox(height: 4),
            SelectableText(user.email ?? '（メールアドレスなし）',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('閉じる')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ログアウト')),
        ],
      ),
    );
    if (signOut == true) {
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ログアウトしました。')),
        );
      }
    }
  }

  // ---- アカウント（Firestore）への保存・読み出し ----

  /// 名前を聞いてアカウントに保存する。同名の図があれば上書きを確認する。
  Future<void> _saveToCloud() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => CloudSaveDialog(initialName: _cloudDiagramName),
    );
    if (name == null || !mounted) return;

    try {
      if (await _cloudService.findIdByName(name) != null) {
        if (!mounted) return;
        final overwrite = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('上書きの確認'),
            content: Text('「$name」はすでに保存されています。上書きしますか？'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('キャンセル')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('上書き')),
            ],
          ),
        );
        if (overwrite != true) return;
      }

      // 中身はローカルの「JSON保存」と同じ形式
      final data = {
        'nodes': _nodes.map((n) => n.toJson()).toList(),
        'edges': _edges.map((e) => e.toJson()).toList(),
        'nodeCounter': _nodeCounter,
      };
      await _cloudService.save(name, jsonEncode(data));
      _cloudDiagramName = name;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「$name」をアカウントに保存しました。')),
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

  /// 自分の図の一覧から選んで開く（一覧から削除もできる）
  Future<void> _openFromCloud() async {
    final selected = await showDialog<CloudDiagram>(
      context: context,
      builder: (ctx) => CloudOpenDialog(service: _cloudService),
    );
    if (selected == null) return;

    try {
      final data = jsonDecode(await _cloudService.load(selected.id));
      _saveToHistory(); // 開く前の図に Undo で戻れるようにする
      setState(() {
        _nodes.clear();
        _edges.clear();
        _nodes.addAll((data['nodes'] as List).map((n) => GsnNode.fromJson(n)));
        _edges.addAll((data['edges'] as List).map((e) => GsnEdge.fromJson(e)));
        _nodeCounter = data['nodeCounter'] ?? 0;
      });
      _saveToLocalStorage();
      _cloudDiagramName = selected.name;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${selected.name}」を開きました。')),
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

// ノードタイプ別の形状ウィジェットを返す。
// Application/Mapはキャンバス上ではラベルを非表示にする（図形の形だけで型が識別できるため）。
// ★追加(Dialectic): defeaterBackedは呼び出し側(_edges等を参照できる箇所)で_isDefeaterBacked()を使って
// 計算し渡す。パレット表示などedges情報が無い場合は既定値false(inDoubtの見た目)のままにする。
Widget _buildGsnShapeWidget(GsnNode node,
    {bool isPalette = false, bool defeaterBacked = false}) {
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

    case GsnNodeType.assumption:
      return buildPainter(AnnotatedOvalPainter(Colors.yellow.shade100, 'A'));

    case GsnNodeType.justification:
      return buildPainter(AnnotatedOvalPainter(Colors.teal.shade100, 'J'));

    case GsnNodeType.defeater: // ★変更(Dialectic): defeaterBackedでdefeated/inDoubtの見た目を切り替える
      return buildPainter(DefeaterPainter(backed: defeaterBacked));

    case GsnNodeType.x:
      return buildPainter(XPainter());

    case GsnNodeType.fileList:
      return Container(
        width: node.width,
        height: node.height,
        decoration: BoxDecoration(
          color: Colors.green.shade100,
          border: Border.all(color: Colors.green.shade700, width: 2),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.table_chart,
                    size: isPalette ? 12 : 16,
                    color: Colors.green.shade800),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    node.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isPalette ? 10 : 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.green.shade900,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: isPalette ? 2 : 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
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
        GsnNodeType.assumption,
        GsnNodeType.justification,
        GsnNodeType.defeater, // ★追加(Defeater)
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
    _PaletteGroup(
      label: 'データ',
      types: [
        GsnNodeType.fileList,
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

// ★追加(接続プレビュー): 接続待ちのあいだ、始点ノードからカーソルまで破線を描く。
// 「いま接続待ちで、次にクリックしたノードが終点になる」ことを見て分かるようにするための
// 表示だけのもので、実際のエッジではないため保存も評価もされない。
// repaintにcursorを渡しているので、マウス移動では図全体をrebuildせずこの層だけ塗り直す。
class ConnectingPreviewPainter extends CustomPainter {
  final List<GsnNode> nodes;
  final int? fromId;
  final ValueNotifier<Offset?> cursor;

  ConnectingPreviewPainter({
    required this.nodes,
    required this.fromId,
    required this.cursor,
  }) : super(repaint: cursor);

  @override
  void paint(Canvas canvas, Size size) {
    final id = fromId;
    final end = cursor.value;
    if (id == null || end == null) return;

    GsnNode? from;
    for (final n in nodes) {
      if (n.id == id) {
        from = n;
        break;
      }
    }
    if (from == null) return;

    final rect = Rect.fromLTWH(
        from.position.dx, from.position.dy, from.width, from.height);
    // カーソルが始点ノードの中にあるあいだは線を出さない（潰れた線になるだけのため）。
    if (rect.contains(end)) return;

    final start = _edgePointToward(rect, end);
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.8)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    _drawDashedPath(
      canvas,
      Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(end.dx, end.dy),
      paint,
    );
    _drawArrowHead(canvas, start, end, paint);
  }

  // 矩形の中心からtowardへ伸ばした半直線が、矩形の枠と交わる点を返す。
  static Offset _edgePointToward(Rect rect, Offset toward) {
    final center = rect.center;
    final d = toward - center;
    if (d.dx == 0 && d.dy == 0) return center;
    // 各軸で枠に届くまでの倍率を出し、小さい方が実際にぶつかる辺になる。
    final tx = d.dx == 0 ? double.infinity : (rect.width / 2) / d.dx.abs();
    final ty = d.dy == 0 ? double.infinity : (rect.height / 2) / d.dy.abs();
    return center + d * min(tx, ty);
  }

  // 終点側に矢尻を描き、どちら向きに繋がるのか（始点→終点）を分かるようにする。
  static void _drawArrowHead(
      Canvas canvas, Offset start, Offset end, Paint paint) {
    const double len = 12;
    const double spread = 0.45; // 開き角(ラジアン)
    final angle = atan2(end.dy - start.dy, end.dx - start.dx);
    canvas.drawLine(
        end, end - Offset(cos(angle - spread), sin(angle - spread)) * len, paint);
    canvas.drawLine(
        end, end - Offset(cos(angle + spread), sin(angle + spread)) * len, paint);
  }

  @override
  bool shouldRepaint(covariant ConnectingPreviewPainter old) =>
      old.fromId != fromId || old.nodes != nodes || old.cursor != cursor;
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
      // ★追加(Dialectic): "challenges"関係（GSN v3のDialectic拡張）は他の関係と区別できるよう
      // 破線・赤系の色で描画する。選択中/削除モードの色は従来通り優先する。
      final isChallenge = _isChallengesEdge(toNode);

      final paint = Paint()
        ..color = isRemovalMode
            ? Colors.red.withOpacity(0.5)
            : (isSelected
                ? Colors.blue.shade800
                : (isChallenge ? Colors.red.shade700 : Colors.black))
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



          // Context / Assumption / Justification は横からエッジを繋ぐ
          // Contextがfromノードより右にあれば右辺→左辺、左なら左辺→右辺
          final toIsPlainSide = _sideAttachedTypes.contains(toNode.type);
          final fromIsPlainSide = _sideAttachedTypes.contains(fromNode.type);

          // ★追加(Defeater): DefeaterはGoal/Strategyに「アタッチされる側(=to)」のときだけ横方向に繋ぐ。
          // Defeaterから自分の反論(Rebuttal)チェーンの子へ向かうエッジ（Defeaterがfrom側）は
          // ここでは対象にせず、下のelse節（通常の縦方向接続）に流す。
          // これによりDefeater自身は横付け、その下の子は普通の親子接続、という描き分けができる。
          final toIsDefeaterAttach = toNode.type == GsnNodeType.defeater;

          final isHorizontalSideEdge = toIsPlainSide || fromIsPlainSide || toIsDefeaterAttach;
          // sideIsTo: 「横に付く側」がto/fromのどちらか（Context等の逆順クリックにも対応するため据え置き）
          final sideIsTo = toIsPlainSide || toIsDefeaterAttach;

          if (isHorizontalSideEdge) {
            // どちらが横付け要素かを判断して、横方向に接続する
            final contextRect  = sideIsTo ? toRect   : fromRect;
            final goalRect     = sideIsTo ? fromRect : toRect;

            // 横付け要素がGoalより右にあるか左にあるかで接続辺を決める
            if (contextRect.center.dx >= goalRect.center.dx) {
              // 右側 → Goalの右辺 → 横付け要素の左辺
              startPoint = sideIsTo ? goalRect.centerRight    : contextRect.centerRight;
              endPoint   = sideIsTo ? contextRect.centerLeft  : goalRect.centerLeft;
            } else {
              // 左側 → Goalの左辺 → 横付け要素の右辺
              startPoint = sideIsTo ? goalRect.centerLeft     : contextRect.centerLeft;
              endPoint   = sideIsTo ? contextRect.centerRight : goalRect.centerRight;
            }
          } else {
            // スタート地点：fromNodeの真ん中下
            startPoint = fromRect.bottomCenter;

            // エンド地点：toNodeの真ん中上
            endPoint = toRect.topCenter;
          }
      }


      // 線を描画（Map引数はL字折れ線、それ以外は直線）
      // ★追加(Dialectic): challengesエッジは破線で描画する
      if (_bend1 != null) {
        // L字折れ線: startPoint → bend1 → (bend2 →) endPoint
        final path = Path()
          ..moveTo(startPoint.dx, startPoint.dy)
          ..lineTo(_bend1!.dx, _bend1!.dy);
        if (_bend2 != null) path.lineTo(_bend2!.dx, _bend2!.dy);
        path.lineTo(endPoint.dx, endPoint.dy);
        if (isChallenge) {
          _drawDashedPath(canvas, path, paint..style = PaintingStyle.stroke);
        } else {
          canvas.drawPath(path, paint..style = PaintingStyle.stroke);
        }
      } else if (isChallenge) {
        final path = Path()
          ..moveTo(startPoint.dx, startPoint.dy)
          ..lineTo(endPoint.dx, endPoint.dy);
        _drawDashedPath(canvas, path, paint..style = PaintingStyle.stroke);
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

// Assumption('A')・Justification('J')共用のPainter。
// GSN標準では楕円に右下の丸バッジで注記を付けて区別する。
class AnnotatedOvalPainter extends CustomPainter {
  final Color color;
  final String letter;
  AnnotatedOvalPainter(this.color, this.letter);

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..color = color;
    final borderPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawOval(rect, fillPaint);
    canvas.drawOval(rect, borderPaint);

    const badgeRadius = 9.0;
    final badgeCenter =
        Offset(size.width - badgeRadius - 2, size.height - badgeRadius - 2);
    canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = Colors.white);
    canvas.drawCircle(badgeCenter, badgeRadius, borderPaint);

    final textPainter = TextPainter(
      text: TextSpan(
        text: letter,
        style: const TextStyle(
            color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      badgeCenter - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) =>
      oldDelegate is! AnnotatedOvalPainter ||
      oldDelegate.color != color ||
      oldDelegate.letter != letter;
}

// ★追加(Defeater): Confidence Argument対応。Goal/Strategyへの疑義(反論)を示す六角形。
// 「警告・要注意」を表す色（赤系）にして、支持側の要素（Evidence/Assumption等）と一目で区別できるようにする。
// ★変更(Dialectic): GSN v3のDialectic拡張が言う2つの状態を見た目で区別する。
// backed=true  → defeated（Evidence等の裏付けを伴う主張による疑義。無効化が確定）: 実線・濃い赤・「!」
// backed=false → inDoubt   （Undeveloped=未対応な主張による疑義。要検討）: 破線・薄い赤・「?」
class DefeaterPainter extends CustomPainter {
  final bool backed;
  DefeaterPainter({this.backed = false});

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..color = backed ? Colors.red.shade200 : Colors.red.shade50;
    final borderPaint = Paint()
      ..color = Colors.red.shade900
      ..strokeWidth = backed ? 2.0 : 1.2
      ..style = PaintingStyle.stroke;

    final w = size.width;
    final h = size.height;
    final cut = w * 0.18; // 六角形の斜め辺の切り欠き幅

    final path = Path()
      ..moveTo(cut, 0)
      ..lineTo(w - cut, 0)
      ..lineTo(w, h / 2)
      ..lineTo(w - cut, h)
      ..lineTo(cut, h)
      ..lineTo(0, h / 2)
      ..close();

    canvas.drawPath(path, fillPaint);
    if (backed) {
      canvas.drawPath(path, borderPaint);
    } else {
      _drawDashedPath(canvas, path, borderPaint);
    }

    // 状態バッジ（右下の丸に "!" / "?"）
    const badgeRadius = 9.0;
    final badgeCenter = Offset(w - badgeRadius - 2, h - badgeRadius - 2);
    canvas.drawCircle(badgeCenter, badgeRadius, Paint()..color = Colors.white);
    canvas.drawCircle(badgeCenter, badgeRadius, borderPaint..style = PaintingStyle.stroke);

    final textPainter = TextPainter(
      text: TextSpan(
        text: backed ? '!' : '?',
        style: TextStyle(
            color: Colors.red.shade900,
            fontSize: 12,
            fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      badgeCenter - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) =>
      oldDelegate is! DefeaterPainter || oldDelegate.backed != backed;
}

// ★追加(PGSN v0.0.4): 未展開の印（GSN規格のUndeveloped）。ノード下辺の中央に上の頂点を接する小さな菱形。
// サーバ(build_gsn.py)の UNDEVELOPED_MARKER_H と高さを揃えること。
const Size _undevelopedMarkerSize = Size(20, 14);

void _paintUndevelopedMarker(Canvas canvas, GsnNode node) {
  final top = Offset(node.position.dx + node.width / 2, node.position.dy + node.height);
  final w = _undevelopedMarkerSize.width / 2;
  final h = _undevelopedMarkerSize.height;
  final path = Path()
    ..moveTo(top.dx, top.dy)
    ..lineTo(top.dx + w, top.dy + h / 2)
    ..lineTo(top.dx, top.dy + h)
    ..lineTo(top.dx - w, top.dy + h / 2)
    ..close();
  canvas.drawPath(path, Paint()..color = Colors.white);
  canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke);
}

// 評価結果ビューアで、ノードの上に未展開の印を重ねて描く
class _UndevelopedMarkerPainter extends CustomPainter {
  final List<GsnNode> nodes;
  _UndevelopedMarkerPainter(this.nodes);

  @override
  void paint(Canvas canvas, Size size) {
    for (final n in nodes) {
      if (n.undeveloped) _paintUndevelopedMarker(canvas, n);
    }
  }

  @override
  bool shouldRepaint(covariant _UndevelopedMarkerPainter oldDelegate) =>
      oldDelegate.nodes != nodes;
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
              // 評価後の図もPDFに保存できるようにする（画面と同じPainterで出力する）
              IconButton(
                icon: const Icon(Icons.picture_as_pdf),
                tooltip: 'PDF保存（評価結果）',
                onPressed: nodes.isEmpty
                    ? null
                    : () async {
                        try {
                          await _exportDiagramPdf(
                            nodes: nodes,
                            edges: edges,
                            edgePainter: _SimpleEdgePainter(nodes, edges),
                            fileName: 'gsn_evaluated.pdf',
                          );
                        } catch (e) {
                          if (context.mounted) _showPdfErrorDialog(context, e);
                        }
                      },
              ),
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
                        child: _buildGsnShapeWidget(
                          node,
                          // ★追加(Dialectic): DefeaterがdefeatedかinDoubtかを表示に反映する
                          defeaterBacked: node.type == GsnNodeType.defeater
                              ? _isDefeaterBacked(node, nodes, edges)
                              : false,
                        ),
                      );
                    }).toList(),
                    // ★追加(PGSN v0.0.4): 未展開の印をノードの下辺に重ねる
                    IgnorePointer(
                      child: CustomPaint(
                        size: Size(canvasWidth, canvasHeight),
                        painter: _UndevelopedMarkerPainter(nodes),
                      ),
                    ),
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
      case GsnNodeType.assumption:
        return Colors.yellow.shade100; // 編集画面のAssumption色
      case GsnNodeType.justification:
        return Colors.teal.shade100; // 編集画面のJustification色
      case GsnNodeType.defeater: // ★追加(Defeater)
        return Colors.red.shade100; // 編集画面のDefeater色
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
  // ★注記(Defeater): このビューアはShapeBorder（楕円/角丸四角形）のみ対応のため、
  // 編集画面のような六角形は再現できない。Defeaterは角丸四角形（既定のradius=8.0）にフォールバックする。
  ShapeBorder _getNodeShape(GsnNodeType type) {
    if (type == GsnNodeType.evidence ||
        type == GsnNodeType.assumption ||
        type == GsnNodeType.justification) {
      // Evidence/Assumption/Justificationは楕円形
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

        // ★追加(Dialectic): challengesエッジ(Defeaterへのアタッチ)は破線・赤系で区別する
        final isChallenge = _isChallengesEdge(toNode);
        final paint = Paint()
          ..color = isChallenge ? Colors.red.shade700 : Colors.black
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;

        if (isChallenge) {
          final path = Path()
            ..moveTo(start.dx, start.dy)
            ..lineTo(end.dx, end.dy);
          _drawDashedPath(canvas, path, paint);
        } else {
          canvas.drawLine(start, end, paint);
        }
      } catch (e) {
        // ノードが見つからない場合はスキップ
      }
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}