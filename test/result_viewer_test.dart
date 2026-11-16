// 評価結果の画面の「確かめるだけ / 差し込んで評価」の切り替えのテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/result_viewer_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';

GsnNode n(int id, GsnNodeType type, String label, {String from = ''}) =>
    GsnNode(id: id, type: type, position: Offset(0, id * 120.0), label: label)
      ..inlinedFrom = from;

Future<void> show(WidgetTester tester, Widget viewer) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: viewer)));
  await tester.pumpAndSettle();
}

void main() {
  final checked = ModuleGraph([
    n(0, GsnNodeType.goal, '全体'),
    n(1, GsnNodeType.moduleReference, 'HW の論証'),
  ], [GsnEdge(0, 1)]);
  final inlined = ModuleGraph([
    n(0, GsnNodeType.goal, '全体'),
    n(1, GsnNodeType.goal, 'HW は安全', from: 'HW'),
  ], [GsnEdge(0, 1)]);

  testWidgets('切り替えると一度だけ評価し直し、そのあとは取っておいた結果を出す', (tester) async {
    var calls = <bool>[];
    await show(
        tester,
        GsnResultViewer(
          nodes: checked.nodes,
          edges: checked.edges,
          inlined: false,
          onEvaluate: (inline) async {
            calls.add(inline);
            return inlined;
          },
        ));
    expect(find.text('HW は安全'), findsNothing);

    await tester.tap(find.text('差し込んで評価'));
    await tester.pumpAndSettle();
    expect(find.text('HW は安全'), findsOneWidget);

    await tester.tap(find.text('確かめるだけ'));
    await tester.pumpAndSettle();
    expect(find.text('HW は安全'), findsNothing);
    await tester.tap(find.text('差し込んで評価'));
    await tester.pumpAndSettle();
    expect(find.text('HW は安全'), findsOneWidget);
    expect(calls, [true]);
  });

  testWidgets('評価し直しに失敗したら元の結果のまま', (tester) async {
    await show(
        tester,
        GsnResultViewer(
          nodes: checked.nodes,
          edges: checked.edges,
          inlined: false,
          onEvaluate: (_) async => null,
        ));
    await tester.tap(find.text('差し込んで評価'));
    await tester.pumpAndSettle();
    expect(find.text('HW は安全'), findsNothing);
    final button = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>));
    expect(button.selected, {false});
  });

  testWidgets('別の図を参照しない図では切り替えを出さない', (tester) async {
    await show(tester, GsnResultViewer(nodes: checked.nodes, edges: checked.edges));
    expect(find.byType(SegmentedButton<bool>), findsNothing);
  });
}
