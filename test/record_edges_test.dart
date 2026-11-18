// Record を線の種類で表す（lib/record_edges.dart）のテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/record_edges_test.dart
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';
import 'package:gsnpaint/edge_edit_dialog.dart';

GsnNode node(int id, GsnNodeType type, [String label = 'x']) =>
    GsnNode(id: id, type: type, position: Offset.zero, label: label);

void main() {
  test('Record から値への線はキー名で入れる線になる（FileList は普通の線）', () {
    final rec = node(0, GsnNodeType.record);
    expect(recordLinkForNewEdge(rec, node(1, GsnNodeType.stringLiteral)),
        RecordLink.label);
    expect(recordLinkForNewEdge(rec, node(1, GsnNodeType.fileList)),
        RecordLink.none);
    expect(recordLinkForNewEdge(node(2, GsnNodeType.application), rec),
        RecordLink.none);
  });

  test('ダイアログの扱い: Record の下はキー名、Record への線は取り出しを選べる', () {
    final rec = node(0, GsnNodeType.record);
    final str = node(1, GsnNodeType.stringLiteral);
    final app = node(2, GsnNodeType.application);
    expect(recordEditModeFor(rec, str, GsnEdge(0, 1)), RecordEditMode.label);
    expect(recordEditModeFor(app, rec, GsnEdge(2, 0)),
        RecordEditMode.accessAllowed);
    expect(recordEditModeFor(app, str, GsnEdge(2, 1)), RecordEditMode.none);
  });

  test('古い要素を線にし、評価の前に同じ形へ戻す', () {
    // Application → RecordAccess(AAA) → Record → RecordLabel(AAA) → String
    final nodes = [
      node(0, GsnNodeType.application),
      node(1, GsnNodeType.recordAccess, 'AAA'),
      node(2, GsnNodeType.record),
      node(3, GsnNodeType.recordLabel, 'AAA'),
      node(4, GsnNodeType.stringLiteral, 'v'),
    ];
    final edges = [GsnEdge(0, 1), GsnEdge(1, 2), GsnEdge(2, 3), GsnEdge(3, 4)];
    expect(absorbRecordNodes(nodes, edges), 2);
    expect(nodes.map((n) => n.id), [0, 2, 4]);
    expect(edges.map((e) => (e.fromId, e.toId, e.recordLink, e.recordKey)), [
      (0, 2, RecordLink.access, 'AAA'),
      (2, 4, RecordLink.label, 'AAA'),
    ]);
    // 保存形式を通っても残る
    final again = edges
        .map((e) => GsnEdge.fromJson(jsonDecode(jsonEncode(e.toJson()))))
        .toList();
    expect(again.map((e) => (e.recordLink, e.recordKey)),
        [(RecordLink.access, 'AAA'), (RecordLink.label, 'AAA')]);

    final ex = expandRecordEdges(nodes, again);
    final byId = {for (final n in ex.nodes) n.id: n};
    String path(GsnEdge e) =>
        '${byId[e.fromId]!.type.name}:${byId[e.fromId]!.label}>'
        '${byId[e.toId]!.type.name}:${byId[e.toId]!.label}';
    expect(ex.edges.map(path), [
      'application:x>recordAccess:AAA',
      'recordAccess:AAA>record:x',
      'record:x>recordLabel:AAA',
      'recordLabel:AAA>stringLiteral:v',
    ]);
  });

  test('入れ子の取り出しや親が Record でない Label は要素のまま残す', () {
    final nodes = [
      node(0, GsnNodeType.goal),
      node(1, GsnNodeType.recordAccess, 'a'),
      node(2, GsnNodeType.recordAccess, 'b'),
      node(3, GsnNodeType.record),
      node(4, GsnNodeType.recordLabel, 'k'),
      node(5, GsnNodeType.stringLiteral),
    ];
    final edges = [
      GsnEdge(0, 1), GsnEdge(1, 2), GsnEdge(2, 3), // 入れ子
      GsnEdge(0, 4), GsnEdge(4, 5), // Goal の下の Label
    ];
    expect(absorbRecordNodes(nodes, edges), 1);
    expect(nodes.where((n) => n.type == GsnNodeType.recordAccess).length, 1);
    expect(nodes.where((n) => n.type == GsnNodeType.recordLabel).length, 1);
  });

  test('キー名が空の線を数える', () {
    expect(
        recordEdgesWithoutKey([
          GsnEdge(0, 1, recordLink: RecordLink.label),
          GsnEdge(0, 2, recordLink: RecordLink.access, recordKey: 'k'),
          GsnEdge(0, 3),
        ]),
        1);
  });
}
