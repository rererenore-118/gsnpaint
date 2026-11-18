// GSN v3 1:4.6 モジュールインタフェース（既定のインタフェース）を、今の図から組み立てる。
// 1:4.6.3 の 1〜6 に沿って、公開している主張・支えが必要な主張・その文脈・引用できる成果物・
// 依存している別のモジュールの要素を一覧にする。
part of 'main.dart';

class InterfaceSection {
  final String title;
  final List<String> items;
  const InterfaceSection(this.title, this.items);
}

String _elementText(GsnNode n) {
  final name = GsnNode._displayName(n.type);
  final label = n.label.trim().isEmpty ? '（説明なし）' : n.label.trim();
  return n.module.isEmpty ? '$name: $label' : '$name: $label ［${n.module}］';
}

List<InterfaceSection> buildModuleInterface(
  List<GsnNode> nodes,
  List<GsnEdge> edges, {
  String moduleName = '',
  DiagramInfo? info,
}) {
  final byId = {for (final n in nodes) n.id: n};
  final children = <int, List<GsnNode>>{};
  final parents = <int, List<GsnNode>>{};
  for (final e in edges) {
    final from = byId[e.fromId];
    final to = byId[e.toId];
    if (from == null || to == null) continue;
    children.putIfAbsent(from.id, () => []).add(to);
    parents.putIfAbsent(to.id, () => []).add(from);
  }
  bool isSide(GsnNode n) => _sideAttachedTypes.contains(n.type);

  final header = [
    'モジュール名: ${moduleName.isEmpty ? '（未保存）' : moduleName}',
    if ((info?.description ?? '').isNotEmpty) '説明: ${info!.description}',
    'インタフェース: 既定（default）',
  ];
  if (info?.isContract ?? false) {
    return [
      InterfaceSection('1. モジュール', header),
      const InterfaceSection('契約モジュール', [
        '契約モジュールは自分のインタフェースを持たず、公開する要素もありません（GSN v3 1:4.7.3）。',
      ]),
    ];
  }

  final goals = nodes.where((n) => n.type == GsnNodeType.goal).toList();
  final publicGoals = goals.where((g) => g.public).toList();
  // 支えが必要な Goal: 「契約で支える予定」、未展開の印、支える子が無いもの
  final needSupport = <GsnNode, String>{};
  for (final g in goals) {
    final supports =
        (children[g.id] ?? [])
            .where((c) => !isSide(c) && c.type != GsnNodeType.defeater)
            .toList();
    if (g.contractPending) {
      needSupport[g] = '契約で支える予定';
    } else if (g.undeveloped) {
      needSupport[g] = '未展開';
    } else if (supports.isEmpty) {
      needSupport[g] = '支えがまだ無い';
    }
  }

  // Goal の文脈: その Goal と祖先に付いた Context / Assumption / Justification（1:4.6.3 の 4）
  List<GsnNode> contextOf(GsnNode goal) {
    final seen = <int>{};
    final result = <GsnNode>[];
    final stack = [goal];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      if (!seen.add(n.id)) continue;
      for (final c in children[n.id] ?? const <GsnNode>[]) {
        if (isSide(c) && !result.contains(c)) result.add(c);
      }
      stack.addAll(
        (parents[n.id] ?? const <GsnNode>[]).where((p) => !isSide(p)),
      );
    }
    return result;
  }

  final contextItems = <String>[];
  for (final g in {...publicGoals, ...needSupport.keys}) {
    final ctx = contextOf(g);
    if (ctx.isEmpty) continue;
    contextItems.add(
      '${_elementText(g)} の文脈: ${ctx.map(_elementText).join('、')}',
    );
  }

  const citable = {
    GsnNodeType.evidence,
    GsnNodeType.context,
    GsnNodeType.assumption,
    GsnNodeType.justification,
  };
  final citableItems =
      nodes
          .where((n) => citable.contains(n.type) && n.public)
          .map(_elementText)
          .toList();

  final deps = <String>[];
  for (final n in nodes.where(_refersToModule)) {
    final supported =
        (parents[n.id] ?? const <GsnNode>[]).map(_elementText).toList();
    deps.add(
      supported.isEmpty
          ? _elementText(n)
          : '${_elementText(n)}  ← ${supported.join('、')}',
    );
  }

  List<String> orNone(List<String> items) => items.isEmpty ? ['なし'] : items;
  return [
    InterfaceSection('1. モジュール', header),
    InterfaceSection(
      '2. このモジュールが論じる主張（公開 Goal）',
      orNone(publicGoals.map(_elementText).toList()),
    ),
    InterfaceSection(
      '3. 支えが必要な Goal',
      orNone([
        for (final e in needSupport.entries)
          '${_elementText(e.key)}（${e.value}）',
      ]),
    ),
    InterfaceSection('4. 上の Goal に関わる文脈', orNone(contextItems)),
    InterfaceSection('5. 他のモジュールから引用できる要素（公開）', orNone(citableItems)),
    InterfaceSection('6. 依存している別のモジュール', orNone(deps)),
  ];
}

String moduleInterfaceText(List<InterfaceSection> sections) => [
  for (final s in sections) ...[
    '■ ${s.title}',
    for (final i in s.items) '・$i',
    '',
  ],
].join('\n');
