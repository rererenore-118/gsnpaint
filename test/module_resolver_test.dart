// Away Goal の参照先の照合と差し込み（ModuleResolver）のテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/module_resolver_test.dart
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';

GsnNode node(int id, GsnNodeType type, String label,
        {String module = '', bool public = false}) =>
    GsnNode(
        id: id,
        type: type,
        position: Offset.zero,
        label: label,
        module: module,
        public: public);

String diagram(List<GsnNode> nodes, List<GsnEdge> edges) => jsonEncode({
      'nodes': nodes.map((n) => n.toJson()).toList(),
      'edges': edges.map((e) => e.toJson()).toList(),
    });

void main() {
  // モジュール「SW」: 公開ゴール「SW は安全」→ Strategy → Evidence と、非公開ゴール「内部」
  final sw = diagram([
    node(0, GsnNodeType.goal, 'SW は安全', public: true),
    node(1, GsnNodeType.strategy, '機能ごとに論じる'),
    node(2, GsnNodeType.evidence, 'SW 試験結果'),
    node(3, GsnNodeType.goal, '内部'),
  ], [
    GsnEdge(0, 1),
    GsnEdge(1, 2),
  ]);
  // モジュール「A」と「B」は互いを参照しあう（循環）
  final a = diagram([
    node(0, GsnNodeType.goal, 'A は安全', public: true),
    node(1, GsnNodeType.awayGoal, 'B は安全', module: 'B'),
  ], [
    GsnEdge(0, 1),
  ]);
  final b = diagram([
    node(5, GsnNodeType.goal, 'B は安全', public: true),
    node(6, GsnNodeType.awayGoal, 'A は安全', module: 'A'),
  ], [
    GsnEdge(5, 6),
  ]);
  final modules = {'SW': sw, 'A': a, 'B': b};
  var loads = 0;
  ModuleResolver resolver() => ModuleResolver((name) async {
        loads++;
        return modules[name];
      });

  test('参照先の状態を確かめる', () async {
    final nodes = [
      node(0, GsnNodeType.awayGoal, 'SW は安全', module: 'SW'),
      node(1, GsnNodeType.awayGoal, '内部', module: 'SW'),
      node(2, GsnNodeType.awayGoal, '無い主張', module: 'SW'),
      node(3, GsnNodeType.awayGoal, 'SW は安全', module: '無い図'),
      node(4, GsnNodeType.awayGoal, 'モジュール名なし'),
    ];
    loads = 0;
    await resolver().check(nodes);
    expect(nodes.map((n) => n.awayStatus), [
      AwayStatus.ok,
      AwayStatus.notPublic,
      AwayStatus.goalMissing,
      AwayStatus.moduleMissing,
      null,
    ]);
    expect(loads, 2, reason: '同じモジュールは1回だけ読む');
  });

  test('参照先の部分木を差し込む', () async {
    final nodes = [
      node(0, GsnNodeType.goal, 'システムは安全'),
      node(1, GsnNodeType.strategy, '構成要素ごとに論じる'),
      node(2, GsnNodeType.awayGoal, 'SW は安全', module: 'SW'),
      node(3, GsnNodeType.defeater, '疑義'),
      node(4, GsnNodeType.awayGoal, '無い主張', module: 'SW'),
    ];
    final edges = [GsnEdge(0, 1), GsnEdge(1, 2), GsnEdge(2, 3), GsnEdge(1, 4)];
    final merged = await resolver().inlineAll(nodes, edges);

    final labels = merged.nodes.map((n) => n.label).toSet();
    expect(labels, containsAll(['SW は安全', '機能ごとに論じる', 'SW 試験結果', '無い主張']));
    expect(labels, isNot(contains('内部')), reason: '公開ゴールの下にない部分は入れない');
    expect(merged.nodes.where((n) => n.type == GsnNodeType.awayGoal).map((n) => n.label),
        ['無い主張'], reason: '見つからない Away Goal は残す');
    expect(merged.nodes.map((n) => n.id).toSet().length, merged.nodes.length,
        reason: 'id が重ならない');

    final root = merged.nodes.firstWhere((n) => n.label == 'SW は安全');
    expect(root.type, GsnNodeType.goal);
    String labelOf(int id) => merged.nodes.firstWhere((n) => n.id == id).label;
    final pairs = merged.edges.map((e) => '${labelOf(e.fromId)}→${labelOf(e.toId)}').toSet();
    expect(pairs, containsAll([
      '構成要素ごとに論じる→SW は安全',
      'SW は安全→疑義',
      'SW は安全→機能ごとに論じる',
      '機能ごとに論じる→SW 試験結果',
    ]));
    // 元の図は変えない
    expect(nodes.length, 5);
    expect(edges.length, 4);
  });

  test('循環する参照は止める', () async {
    final nodes = [node(0, GsnNodeType.awayGoal, 'A は安全', module: 'A')];
    final merged = await resolver().inlineAll(nodes, []);
    // A → B → A（ここで止まり Away Goal のまま残る）
    expect(merged.nodes.map((n) => '${n.type.name}:${n.label}').toSet(), {
      'goal:A は安全',
      'goal:B は安全',
      'awayGoal:A は安全',
    });
  });
}
