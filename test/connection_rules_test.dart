// 線を引くときのつなぎ方のルールのテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/connection_rules_test.dart
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';

GsnNode node(int id, GsnNodeType type) =>
    GsnNode(id: id, type: type, position: Offset.zero, label: 'x');

String? check(GsnNodeType parent, GsnNodeType child, {List<GsnEdge> edges = const []}) =>
    connectionBlockedReason(node(0, parent), node(1, child), edges);

void main() {
  test('普通の GSN のつなぎ方は引ける', () {
    const ok = [
      (GsnNodeType.goal, GsnNodeType.strategy),
      (GsnNodeType.goal, GsnNodeType.evidence),
      (GsnNodeType.goal, GsnNodeType.goal),
      (GsnNodeType.goal, GsnNodeType.context),
      (GsnNodeType.goal, GsnNodeType.assumption),
      (GsnNodeType.goal, GsnNodeType.defeater),
      (GsnNodeType.goal, GsnNodeType.awayGoal),
      (GsnNodeType.goal, GsnNodeType.application),
      (GsnNodeType.strategy, GsnNodeType.goal),
      (GsnNodeType.strategy, GsnNodeType.awayGoal),
      (GsnNodeType.strategy, GsnNodeType.evidence),
      (GsnNodeType.strategy, GsnNodeType.justification),
      (GsnNodeType.strategy, GsnNodeType.map),
      (GsnNodeType.evidence, GsnNodeType.defeater),
      (GsnNodeType.awaySolution, GsnNodeType.defeater),
      (GsnNodeType.awayGoal, GsnNodeType.context),
      (GsnNodeType.awayGoal, GsnNodeType.defeater),
      (GsnNodeType.defeater, GsnNodeType.goal),
      (GsnNodeType.defeater, GsnNodeType.defeater),
      // λ 系の下は調べない
      (GsnNodeType.lambda, GsnNodeType.goal),
      (GsnNodeType.record, GsnNodeType.recordLabel),
    ];
    for (final (p, c) in ok) {
      expect(check(p, c), isNull, reason: '$p → $c');
    }
  });

  test('Context・Assumption・Justification・未展開の下には何も付けられない', () {
    for (final p in [
      GsnNodeType.context,
      GsnNodeType.assumption,
      GsnNodeType.justification,
      GsnNodeType.awayContext,
      GsnNodeType.awayAssumption,
      GsnNodeType.awayJustification,
      GsnNodeType.undeveloped,
    ]) {
      expect(check(p, GsnNodeType.goal), contains('何も付けられません'), reason: '$p');
      expect(check(p, GsnNodeType.defeater), contains('何も付けられません'), reason: '$p');
    }
  });

  test('Evidence と Away Solution の下は Defeater だけ', () {
    expect(check(GsnNodeType.evidence, GsnNodeType.goal), 'Evidence の下に付けられるのは Defeater だけです。');
    expect(check(GsnNodeType.evidence, GsnNodeType.context), isNotNull);
    expect(check(GsnNodeType.awaySolution, GsnNodeType.evidence), isNotNull);
  });

  test('Strategy の下に評価で使われない要素は付けられない', () {
    expect(check(GsnNodeType.strategy, GsnNodeType.stringLiteral), contains('Strategy の下に'));
    expect(check(GsnNodeType.strategy, GsnNodeType.lambda), isNotNull);
    expect(check(GsnNodeType.strategy, GsnNodeType.record), isNotNull);
  });

  test('Away Goal の下に支える子は付けられない（これまでどおり）', () {
    expect(check(GsnNodeType.awayGoal, GsnNodeType.strategy), contains('Away Goal'));
    expect(check(GsnNodeType.awayGoal, GsnNodeType.evidence), contains('Away Goal'));
  });

  test('同じ線の二重引きと、輪になる線は引けない', () {
    final g0 = node(0, GsnNodeType.goal);
    final s1 = node(1, GsnNodeType.strategy);
    final g2 = node(2, GsnNodeType.goal);
    final edges = [GsnEdge(0, 1), GsnEdge(1, 2)];
    expect(connectionBlockedReason(g0, s1, edges), contains('すでに'));
    expect(connectionBlockedReason(g2, g0, edges), contains('輪'));
    expect(connectionBlockedReason(s1, g0, edges), contains('輪'));
    expect(connectionBlockedReason(g0, g0, edges), contains('自分自身'));
    // 逆向きでなく、別の枝へつなぐのは引ける
    expect(connectionBlockedReason(g0, g2, edges), isNull);
  });
}
