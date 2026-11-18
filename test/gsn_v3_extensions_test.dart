// GSN v3 の残りの記法（契約・ACP・テンプレート・アーキテクチャ図・モジュールインタフェース）のテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/gsn_v3_extensions_test.dart
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';
import 'package:gsnpaint/diagram_settings_dialog.dart';
import 'package:gsnpaint/edge_edit_dialog.dart';

GsnNode node(int id, GsnNodeType type,
        {String label = 'x', String module = '', bool public = false}) =>
    GsnNode(
        id: id,
        type: type,
        position: Offset.zero,
        label: label,
        module: module,
        public: public);

String? check(GsnNodeType parent, GsnNodeType child,
        {List<GsnEdge> edges = const [], bool contract = false}) =>
    connectionBlockedReason(node(0, parent), node(1, child), edges,
        contractModule: contract);

void main() {
  group('つなぎ方', () {
    test('アーキテクチャ図の記号は Module / Contract どうしだけ', () {
      expect(check(GsnNodeType.archModule, GsnNodeType.archContract), isNull);
      expect(check(GsnNodeType.archContract, GsnNodeType.archModule), isNull);
      expect(check(GsnNodeType.goal, GsnNodeType.archModule), isNotNull);
      expect(check(GsnNodeType.archModule, GsnNodeType.goal), isNotNull);
      // 逆向きの線がすでにあれば、両端の矢じりで表す
      expect(
          check(GsnNodeType.archModule, GsnNodeType.archModule,
              edges: [GsnEdge(1, 0)]),
          isNotNull);
    });

    test('Instantiation Data は GSN の要素へ 1 本だけ', () {
      expect(check(GsnNodeType.instantiationData, GsnNodeType.goal), isNull);
      expect(check(GsnNodeType.goal, GsnNodeType.instantiationData), isNotNull);
      expect(check(GsnNodeType.instantiationData, GsnNodeType.lambda), isNotNull);
      expect(
          check(GsnNodeType.instantiationData, GsnNodeType.goal,
              edges: [GsnEdge(0, 5)]),
          isNotNull);
    });

    test('Contract Reference は Goal / Strategy の下に置け、下には何も付かない', () {
      expect(check(GsnNodeType.goal, GsnNodeType.contractReference), isNull);
      expect(check(GsnNodeType.strategy, GsnNodeType.contractReference), isNull);
      expect(check(GsnNodeType.contractReference, GsnNodeType.goal), isNotNull);
    });

    test('契約モジュールでは Away Goal を Goal / Strategy / Away Goal で支えられる', () {
      expect(check(GsnNodeType.awayGoal, GsnNodeType.goal), isNotNull);
      for (final t in [
        GsnNodeType.goal,
        GsnNodeType.strategy,
        GsnNodeType.awayGoal
      ]) {
        expect(check(GsnNodeType.awayGoal, t, contract: true), isNull);
      }
      expect(check(GsnNodeType.awayGoal, GsnNodeType.evidence, contract: true),
          isNotNull);
    });
  });

  test('ACP・契約で支える予定・幹の印・アーキテクチャの線は保存形式を行き来する', () {
    final n = node(1, GsnNodeType.goal)
      ..contractPending = true
      ..choice = ''
      ..choiceMultiplicity = EdgeMultiplicity.optional;
    final back = GsnNode.fromJson(n.toJson());
    expect(back.contractPending, isTrue);
    expect(back.choiceMultiplicity, EdgeMultiplicity.optional);
    final e = node(2, GsnNodeType.evidence)..acp = 'ACP1';
    expect(GsnNode.fromJson(e.toJson()).acp, 'ACP1');
    expect(node(3, GsnNodeType.goal).toJson().containsKey('acp'), isFalse);

    final link = GsnEdge(1, 2,
        acp: 'ACP2',
        archHead: ModuleLinkEnd.context,
        archTail: ModuleLinkEnd.composite,
        fromInterface: 'i1');
    final linkBack = GsnEdge.fromJson(link.toJson());
    expect(linkBack.acp, 'ACP2');
    expect(linkBack.archHead, ModuleLinkEnd.context);
    expect(linkBack.archTail, ModuleLinkEnd.composite);
    expect(linkBack.fromInterface, 'i1');
    expect(GsnEdge.fromJson(GsnEdge(1, 2).toJson()).archHead,
        ModuleLinkEnd.supported);
    expect(linkBack.copyWith(fromId: 9).acp, 'ACP2');
  });

  test('モジュールインタフェースを今の図から組み立てる', () {
    final g1 = node(0, GsnNodeType.goal, label: 'システムは安全', public: true);
    final c1 = node(1, GsnNodeType.context, label: '運用環境');
    final s1 = node(2, GsnNodeType.strategy, label: '部品ごと');
    final g2 = node(3, GsnNodeType.goal, label: 'SW は安全')..contractPending = true;
    final a1 = node(4, GsnNodeType.awayGoal, label: 'HW は安全', module: 'HW');
    final e1 = node(5, GsnNodeType.evidence, label: '試験', public: true);
    final sections = buildModuleInterface(
      [g1, c1, s1, g2, a1, e1],
      [
        GsnEdge(0, 1),
        GsnEdge(0, 2),
        GsnEdge(2, 3),
        GsnEdge(2, 4),
        GsnEdge(2, 5),
      ],
      moduleName: '本体',
    );
    final byTitle = {for (final s in sections) s.title: s.items};
    expect(byTitle['2. このモジュールが論じる主張（公開 Goal）'], ['Goal: システムは安全']);
    expect(byTitle['3. 支えが必要な Goal'], ['Goal: SW は安全（契約で支える予定）']);
    // SW は安全 の文脈は、祖先の Goal に付いた Context も含む
    expect(byTitle['4. 上の Goal に関わる文脈']!.join(),
        contains('Goal: SW は安全 の文脈: Context: 運用環境'));
    expect(byTitle['5. 他のモジュールから引用できる要素（公開）'], ['Evidence: 試験']);
    expect(byTitle['6. 依存している別のモジュール'],
        ['AwayGoal: HW は安全 ［HW］  ← Strategy: 部品ごと']);
  });

  test('契約モジュールのインタフェースは無い', () {
    final sections = buildModuleInterface([], [],
        info: DiagramInfo(kind: DiagramKind.contract));
    expect(sections.last.title, '契約モジュール');
  });

  group('Contract Reference の解決', () {
    String diagram(List<GsnNode> nodes, List<GsnEdge> edges,
            {bool contract = false}) =>
        jsonEncode({
          'nodes': nodes.map((n) => n.toJson()).toList(),
          'edges': edges.map((e) => e.toJson()).toList(),
          if (contract) 'diagram': {'kind': 'contract'},
        });
    // 契約「C」: 本体の「SW は安全」を、SW モジュールの「SW 部品は安全」で支える
    final contract = diagram([
      node(0, GsnNodeType.awayGoal, label: 'SW は安全', module: '本体'),
      node(1, GsnNodeType.awayGoal, label: 'SW 部品は安全', module: 'SW'),
    ], [
      GsnEdge(0, 1)
    ], contract: true);
    final sw = diagram([
      node(0, GsnNodeType.goal, label: 'SW 部品は安全', public: true),
      node(1, GsnNodeType.evidence, label: '試験'),
    ], [
      GsnEdge(0, 1)
    ]);
    final notContract = diagram([node(0, GsnNodeType.goal, label: 'G')], []);
    final store = {'C': contract, 'SW': sw, 'N': notContract};
    ModuleResolver resolver() => ModuleResolver((name) async => store[name]);

    test('契約モジュールでなければ参照先にならない', () async {
      final ref = node(1, GsnNodeType.contractReference, module: 'N');
      await resolver().check([ref]);
      expect(ref.awayStatus, AwayStatus.notContract);
      final ok = node(1, GsnNodeType.contractReference, module: 'C');
      await resolver().check([ok]);
      expect(ok.awayStatus, AwayStatus.ok);
    });

    test('差し込むと契約の中身を通って別のモジュールの論証までつながる', () async {
      final top = node(0, GsnNodeType.goal, label: 'SW は安全');
      final ref = node(1, GsnNodeType.contractReference, module: 'C');
      final merged = await resolver().inlineAll([top, ref], [GsnEdge(0, 1)]);
      final labels = merged.nodes.map((n) => n.label).toSet();
      expect(labels, containsAll(['SW は安全', 'SW 部品は安全', '試験']));
      expect(merged.nodes.any((n) => n.type == GsnNodeType.contractReference),
          isFalse);
      expect(merged.nodes.any((n) => n.type == GsnNodeType.awayGoal), isFalse);
    });
  });
}
