// 編集ダイアログの内容をノードへ反映する処理のテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/node_apply_edit_test.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';
import 'package:gsnpaint/node_edit_dialog.dart';

GsnNode node(int id, GsnNodeType type, {String label = 'x', String module = ''}) =>
    GsnNode(id: id, type: type, position: Offset.zero, label: label, module: module);

NodeEditResult edit({bool away = false, String module = '', bool public = false}) =>
    NodeEditResult(
        label: 'y', isAway: away, module: module, isPublic: public, isUndeveloped: false);

void main() {
  const pairs = {
    GsnNodeType.goal: 'AwayGoal',
    GsnNodeType.evidence: 'AwaySolution',
    GsnNodeType.context: 'AwayContext',
    GsnNodeType.assumption: 'AwayAssumption',
    GsnNodeType.justification: 'AwayJustification',
  };

  pairs.forEach((type, awayName) {
    test('$type は $awayName に切り替えて保存でき、外すと戻る', () {
      final n = node(1, type)..public = true;
      n.applyEdit(edit(away: true, module: 'M'));
      final json = n.toJson();
      expect(json['gsn_type'], awayName);
      expect(json['module'], 'M');
      expect(json['description'], 'y');
      expect(n.public, isFalse);

      final restored = GsnNode.fromJson(json);
      expect(restored.type, n.type);
      restored.applyEdit(edit());
      expect(restored.type, type);
      expect(restored.module, '');
    });
  });

  test('参照先になれない種類は種類が変わらない', () {
    final n = node(1, GsnNodeType.strategy)..applyEdit(edit());
    expect(n.type, GsnNodeType.strategy);
  });

  test('Away Goal には支える子だけをつなげない', () {
    final a = node(0, GsnNodeType.awayGoal);
    expect(wouldDecomposeAwayGoal(a, node(1, GsnNodeType.goal)), isTrue);
    expect(wouldDecomposeAwayGoal(a, node(2, GsnNodeType.strategy)), isTrue);
    expect(wouldDecomposeAwayGoal(a, node(3, GsnNodeType.evidence)), isTrue);
    expect(wouldDecomposeAwayGoal(a, node(4, GsnNodeType.awaySolution)), isTrue);
    expect(wouldDecomposeAwayGoal(a, node(5, GsnNodeType.context)), isFalse);
    expect(wouldDecomposeAwayGoal(a, node(6, GsnNodeType.defeater)), isFalse);
    expect(wouldDecomposeAwayGoal(node(7, GsnNodeType.goal), node(8, GsnNodeType.goal)), isFalse);
  });

  test('Goal の下の支える子だけを、Away にできない理由として数える', () {
    final g = node(0, GsnNodeType.goal);
    final s = node(1, GsnNodeType.strategy);
    final c = node(2, GsnNodeType.context);
    final d = node(3, GsnNodeType.defeater);
    final e = node(4, GsnNodeType.evidence);
    final all = [g, s, c, d, e];
    expect(hasSupportingChild(g, all, [GsnEdge(0, 2), GsnEdge(0, 3)]), isFalse);
    expect(hasSupportingChild(g, all, [GsnEdge(0, 1)]), isTrue);
    expect(hasSupportingChild(g, all, [GsnEdge(0, 4)]), isTrue);
    expect(hasSupportingChild(s, all, [GsnEdge(1, 4)]), isFalse);
  });
}
