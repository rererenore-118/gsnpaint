// GSN v3 モジュール拡張: Away 要素（Goal / Evidence / Context / Assumption / Justification）と
// Module Reference が参照するモジュールを解決する。
//
// Away 要素は参照先の公開された 1 つの要素を、Module Reference は参照先のモジュールの論証全体
// （トップゴールから下）を指す。
// モジュールはアカウントに保存した図（名前で引く）で、Away 要素から参照できるのは
// 「公開」の印を付けた同じ種類の要素だけ。説明文が一致するものを参照先とみなす。
// 評価用Python は Firestore を読めないので、参照先の読み込みと照合はすべてここで行う。
part of 'main.dart';

enum AwayStatus { ok, moduleMissing, goalMissing, notPublic, noTopGoal, manyTopGoals, notChecked }

String _awayStatusText(AwayStatus s) => switch (s) {
      AwayStatus.ok => '参照OK',
      AwayStatus.moduleMissing => '図がありません',
      AwayStatus.goalMissing => '参照先の要素が見つかりません',
      AwayStatus.notPublic => '公開されていません',
      AwayStatus.noTopGoal => 'トップの Goal がありません',
      AwayStatus.manyTopGoals => 'トップの Goal が 1 つに決まりません',
      AwayStatus.notChecked => '未確認',
    };

class ModuleGraph {
  final List<GsnNode> nodes;
  final List<GsnEdge> edges;
  ModuleGraph(this.nodes, this.edges);
}

class ModuleResolver {
  // モジュール名から図の中身（保存したJSON）を返す。無ければ null。
  final Future<String?> Function(String name) _loadByName;
  // 1回の評価の中では、同じモジュールを何度参照しても読み込みは1回にする
  final Map<String, ModuleGraph?> _cache = {};
  // 差し込んだノードに振る新しい id（評価する図の中で重ならないようにする）
  int _nextId = 0;

  ModuleResolver(this._loadByName);

  /// アカウントに保存した図をモジュールとして読む
  ModuleResolver.cloud(CloudDiagramService service)
      : this((name) async {
          final id = await service.findIdByName(name);
          return id == null ? null : await service.load(id);
        });

  Future<ModuleGraph?> _load(String name) async {
    if (_cache.containsKey(name)) return _cache[name];
    ModuleGraph? graph;
    final content = await _loadByName(name);
    if (content != null) {
      final data = jsonDecode(content);
      graph = ModuleGraph(
        (data['nodes'] as List).map((n) => GsnNode.fromJson(n)).toList(),
        (data['edges'] as List).map((e) => GsnEdge.fromJson(e)).toList(),
      );
    }
    return _cache[name] = graph;
  }

  /// 参照先のモジュールから、Away 要素と同じ文面の公開された要素（[targetType] の種類）を探す
  Future<(AwayStatus, GsnNode?, ModuleGraph?)> find(
      String module, String claim, GsnNodeType targetType) async {
    final graph = await _load(module);
    if (graph == null) return (AwayStatus.moduleMissing, null, null);
    final same = graph.nodes
        .where((n) => n.type == targetType && n.label.trim() == claim.trim())
        .toList();
    if (same.isEmpty) return (AwayStatus.goalMissing, null, graph);
    final public = same.where((n) => n.public).toList();
    if (public.isEmpty) return (AwayStatus.notPublic, null, graph);
    return (AwayStatus.ok, public.first, graph);
  }

  /// Module Reference の参照先: モジュールのトップゴール（親を持たない Goal）。
  /// 論証全体を指すので「公開」の印は問わない。トップゴールがちょうど 1 つのときだけ見つかったとする。
  Future<(AwayStatus, GsnNode?, ModuleGraph?)> findTopGoal(String module) async {
    final graph = await _load(module);
    if (graph == null) return (AwayStatus.moduleMissing, null, null);
    final children = {for (final e in graph.edges) e.toId};
    final tops = graph.nodes
        .where((n) => n.type == GsnNodeType.goal && !children.contains(n.id))
        .toList();
    if (tops.isEmpty) return (AwayStatus.noTopGoal, null, graph);
    if (tops.length > 1) return (AwayStatus.manyTopGoals, null, graph);
    return (AwayStatus.ok, tops.single, graph);
  }

  // 参照する要素の種類に応じて、参照先を探す
  Future<(AwayStatus, GsnNode?, ModuleGraph?)> _findFor(GsnNode n) {
    if (n.type == GsnNodeType.moduleReference) return findTopGoal(n.module);
    return find(n.module, n.label, _awayTargetTypes[n.type]!);
  }

  /// モジュールの公開された要素の説明文の一覧（Away 要素の編集で選べるようにする）。図が無ければ null。
  Future<List<String>?> publicClaims(String module,
      {GsnNodeType targetType = GsnNodeType.goal}) async {
    final graph = await _load(module);
    return graph?.nodes
        .where((n) => n.type == targetType && n.public)
        .map((n) => n.label.trim())
        .toList();
  }

  /// 評価結果の Away 要素と Module Reference それぞれに、参照先が見つかるかどうかを付ける
  Future<void> check(List<GsnNode> nodes) async {
    for (final n in nodes) {
      if (!_refersToModule(n)) continue;
      n.awayStatus = (await _findFor(n)).$1;
    }
  }

  /// Away 要素を参照先の公開された要素とその下の部分木に、Module Reference を参照先の
  /// トップゴールから下の論証全体に置き換えた図を返す。元の図は変えない。
  /// 参照先が見つからない要素はそのまま残す（評価のあとの check() で理由が分かる）。
  Future<ModuleGraph> inlineAll(List<GsnNode> nodes, List<GsnEdge> edges) {
    _nextId = nodes.fold(0, (m, n) => max(m, n.id)) + 1;
    return _inline(nodes, edges, {});
  }

  // [visiting] は今たどっているモジュールの名前。同じモジュールに戻ってきた（循環した）ら、
  // その Away 要素は置き換えずに残して止める。
  Future<ModuleGraph> _inline(
      List<GsnNode> nodes, List<GsnEdge> edges, Set<String> visiting) async {
    final outNodes = List<GsnNode>.of(nodes);
    var outEdges = List<GsnEdge>.of(edges);

    for (final away in nodes) {
      if (!_refersToModule(away)) continue;
      if (visiting.contains(away.module)) continue;
      final (status, target, graph) = await _findFor(away);
      if (status != AwayStatus.ok) continue;

      // 公開された要素から下の部分木を、新しい id に付け替えて取り出す
      final ids = _descendants(target!.id, graph!.edges);
      final idMap = {for (final id in ids) id: _nextId++};
      final subNodes = graph.nodes
          .where((n) => ids.contains(n.id))
          .map((n) => n.copyWithId(idMap[n.id]!))
          .toList();
      final subEdges = graph.edges
          .where((e) => ids.contains(e.fromId) && ids.contains(e.toId))
          .map((e) => GsnEdge(idMap[e.fromId]!, idMap[e.toId]!))
          .toList();
      final sub = await _inline(subNodes, subEdges, {...visiting, away.module});

      // Away 要素につながっていた線は、差し込んだ要素につなぎ直す
      final root = idMap[target.id]!;
      outNodes.remove(away);
      outNodes.addAll(sub.nodes);
      outEdges = [
        for (final e in outEdges)
          GsnEdge(e.fromId == away.id ? root : e.fromId,
              e.toId == away.id ? root : e.toId),
        ...sub.edges,
      ];
    }
    return ModuleGraph(outNodes, outEdges);
  }

  static Set<int> _descendants(int rootId, List<GsnEdge> edges) {
    final seen = <int>{rootId};
    final queue = [rootId];
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      for (final e in edges) {
        if (e.fromId == id && seen.add(e.toId)) queue.add(e.toId);
      }
    }
    return seen;
  }
}
