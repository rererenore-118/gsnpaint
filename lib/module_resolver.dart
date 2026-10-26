// GSN v3 モジュール拡張: Away Goal が参照するモジュールを解決する。
//
// モジュールはアカウントに保存した図（名前で引く）で、Away Goal から参照できるのは
// 「公開」の印を付けた Goal だけ。主張の文面が一致するものを参照先とみなす。
// 評価用Python は Firestore を読めないので、参照先の読み込みと照合はすべてここで行う。
part of 'main.dart';

enum AwayStatus { ok, moduleMissing, goalMissing, notPublic, notChecked }

String _awayStatusText(AwayStatus s) => switch (s) {
      AwayStatus.ok => '参照OK',
      AwayStatus.moduleMissing => '図がありません',
      AwayStatus.goalMissing => '主張が見つかりません',
      AwayStatus.notPublic => '公開されていません',
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

  /// 参照先のモジュールから、Away Goal と同じ文面の公開ゴールを探す
  Future<(AwayStatus, GsnNode?, ModuleGraph?)> find(
      String module, String claim) async {
    final graph = await _load(module);
    if (graph == null) return (AwayStatus.moduleMissing, null, null);
    final same = graph.nodes
        .where((n) => n.type == GsnNodeType.goal && n.label.trim() == claim.trim())
        .toList();
    if (same.isEmpty) return (AwayStatus.goalMissing, null, graph);
    final public = same.where((n) => n.public).toList();
    if (public.isEmpty) return (AwayStatus.notPublic, null, graph);
    return (AwayStatus.ok, public.first, graph);
  }

  /// 評価結果の Away Goal それぞれに、参照先が見つかるかどうかを付ける
  Future<void> check(List<GsnNode> nodes) async {
    for (final n in nodes) {
      if (n.type != GsnNodeType.awayGoal || n.module.isEmpty) continue;
      n.awayStatus = (await find(n.module, n.label)).$1;
    }
  }

  /// Away Goal を、参照先の公開ゴールとその下の部分木に置き換えた図を返す。元の図は変えない。
  /// 参照先が見つからない Away Goal はそのまま残す（評価のあとの check() で理由が分かる）。
  Future<ModuleGraph> inlineAll(List<GsnNode> nodes, List<GsnEdge> edges) {
    _nextId = nodes.fold(0, (m, n) => max(m, n.id)) + 1;
    return _inline(nodes, edges, {});
  }

  // [visiting] は今たどっているモジュールの名前。同じモジュールに戻ってきた（循環した）ら、
  // その Away Goal は置き換えずに残して止める。
  Future<ModuleGraph> _inline(
      List<GsnNode> nodes, List<GsnEdge> edges, Set<String> visiting) async {
    final outNodes = List<GsnNode>.of(nodes);
    var outEdges = List<GsnEdge>.of(edges);

    for (final away in nodes) {
      if (away.type != GsnNodeType.awayGoal || away.module.isEmpty) continue;
      if (visiting.contains(away.module)) continue;
      final (status, goal, graph) = await find(away.module, away.label);
      if (status != AwayStatus.ok) continue;

      // 公開ゴールから下の部分木を、新しい id に付け替えて取り出す
      final ids = _descendants(goal!.id, graph!.edges);
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

      // Away Goal につながっていた線は、差し込んだゴールにつなぎ直す
      final root = idMap[goal.id]!;
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
