// PGSN の Record を線の種類で表す。
// 以前は Record → RecordLabel → 値、親 → RecordAccess → Record のように、名前（キー）だけを持つ
// 要素を線の途中に置いていた。どちらも親 1・子 1 のつなぎ方に名前を付けるだけなので、
// 線に種類とキー名を持たせ、Label は一本線、Access は二重線で描く。
// 評価側（build_gsn.py）は要素のままの形を読むので、評価に送る直前に要素へ戻す。
part of 'main.dart';

/// 線を引いたときの種類。Record から値（FileList 以外）への線は、必ずキー名で入れる線になる。
RecordLink recordLinkForNewEdge(GsnNode parent, GsnNode child) =>
    parent.type == GsnNodeType.record && child.type != GsnNodeType.fileList
        ? RecordLink.label
        : RecordLink.none;

/// 線の設定ダイアログで Record のキーをどう扱うか。
RecordEditMode recordEditModeFor(GsnNode from, GsnNode to, GsnEdge edge) {
  if (from.type == GsnNodeType.record) {
    return to.type == GsnNodeType.fileList
        ? RecordEditMode.none
        : RecordEditMode.label;
  }
  // 値を取り出せるのは Record（と、古い図に残った RecordAccess の要素）から
  if (to.type == GsnNodeType.record ||
      to.type == GsnNodeType.recordAccess ||
      edge.recordLink == RecordLink.access) {
    return RecordEditMode.accessAllowed;
  }
  return RecordEditMode.none;
}

/// キー名が空の Record の線の数（評価の前に確かめる）
int recordEdgesWithoutKey(Iterable<GsnEdge> edges) => edges
    .where((e) => e.recordLink != RecordLink.none && e.recordKey.trim().isEmpty)
    .length;

/// 古い図の RecordLabel / RecordAccess の要素を線に置き換える。置き換えた数を返す。
/// 親 1・子 1 でつながっていて、線にしても意味が変わらないものだけを置き換え、
/// それ以外（入れ子の取り出しなど）は要素のまま残す。
int absorbRecordNodes(List<GsnNode> nodes, List<GsnEdge> edges) {
  final byId = {for (final n in nodes) n.id: n};
  final absorbed = <int>{};
  for (final n in nodes) {
    final link = switch (n.type) {
      GsnNodeType.recordLabel => RecordLink.label,
      GsnNodeType.recordAccess => RecordLink.access,
      _ => null,
    };
    if (link == null) continue;
    final ins = edges.where((e) => e.toId == n.id).toList();
    final outs = edges.where((e) => e.fromId == n.id).toList();
    if (ins.length != 1 || outs.length != 1) continue;
    final inEdge = ins.single;
    final outEdge = outs.single;
    // 前後の線がすでに Record の線（入れ子）なら、1 本の線にはまとめられない
    if (inEdge.recordLink != RecordLink.none ||
        outEdge.recordLink != RecordLink.none) {
      continue;
    }
    final parent = byId[inEdge.fromId];
    if (parent == null || byId[outEdge.toId] == null) continue;
    // キー名で入れる線は Record の下にだけ置ける
    if (link == RecordLink.label && parent.type != GsnNodeType.record) continue;
    if (inEdge.fromId == outEdge.toId ||
        edges.any((e) => e.fromId == inEdge.fromId && e.toId == outEdge.toId)) {
      continue;
    }
    edges[edges.indexOf(inEdge)] = inEdge.copyWith(toId: outEdge.toId)
      ..recordLink = link
      ..recordKey = n.label;
    edges.remove(outEdge);
    absorbed.add(n.id);
  }
  nodes.removeWhere((n) => absorbed.contains(n.id));
  return absorbed.length;
}

/// 評価に送る形: Record の線を RecordLabel / RecordAccess の要素とその前後の線に戻す。
/// 子の順番が変わらないよう、線のあった位置に 2 本の線を置く。
({List<GsnNode> nodes, List<GsnEdge> edges}) expandRecordEdges(
    List<GsnNode> nodes, List<GsnEdge> edges) {
  if (edges.every((e) => e.recordLink == RecordLink.none)) {
    return (nodes: nodes, edges: edges);
  }
  final byId = {for (final n in nodes) n.id: n};
  var nextId = nodes.fold<int>(-1, (m, n) => max(m, n.id)) + 1;
  final outNodes = [...nodes];
  final outEdges = <GsnEdge>[];
  for (final e in edges) {
    if (e.recordLink == RecordLink.none) {
      outEdges.add(e);
      continue;
    }
    final id = nextId++;
    final child = byId[e.toId];
    outNodes.add(GsnNode(
      id: id,
      type: e.recordLink == RecordLink.label
          ? GsnNodeType.recordLabel
          : GsnNodeType.recordAccess,
      position: (child?.position ?? Offset.zero) - const Offset(0, 70),
      label: e.recordKey,
    ));
    outEdges
      ..add(GsnEdge(e.fromId, id))
      ..add(GsnEdge(id, e.toId));
  }
  return (nodes: outNodes, edges: outEdges);
}
