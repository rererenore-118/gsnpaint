// 線の設定ダイアログ（GSN v3 の Multiplicity / Optionality）のテスト。
//   flutter test test/edge_edit_dialog_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/edge_edit_dialog.dart';

Future<List<EdgeEditResult?>> open(WidgetTester tester, EdgeEditDialog dialog) async {
  final results = <EdgeEditResult?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          results.add(await showDialog<EdgeEditResult>(
            context: context,
            builder: (_) => dialog,
          ));
        },
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('黒丸を選んで個数を入れられる', (tester) async {
    final results = await open(tester, const EdgeEditDialog(title: 'Goal → Goal の線'));
    await tester.tap(find.text('複数（●）'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' 0..x ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(results.single!.multiplicity, EdgeMultiplicity.many);
    expect(results.single!.cardinality, '0..x');
    expect(results.single!.delete, isFalse);
  });

  testWidgets('白丸に変えると個数は消える', (tester) async {
    final results = await open(
        tester,
        const EdgeEditDialog(
            title: 't',
            initialMultiplicity: EdgeMultiplicity.many,
            initialCardinality: 'n'));
    await tester.tap(find.text('任意（○）'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(results.single!.multiplicity, EdgeMultiplicity.optional);
    expect(results.single!.cardinality, '');
  });

  testWidgets('GSN 以外の線は削除だけ', (tester) async {
    final results =
        await open(tester, const EdgeEditDialog(title: 't', canDecorate: false));
    expect(find.text('保存'), findsNothing);
    await tester.tap(find.text('線を削除'));
    await tester.pumpAndSettle();
    expect(results.single!.delete, isTrue);
  });

  test('保存形式の文字列と行き来できる', () {
    for (final m in EdgeMultiplicity.values) {
      expect(edgeMultiplicityFromJson(edgeMultiplicityToJson(m)), m);
    }
    expect(edgeMultiplicityToJson(EdgeMultiplicity.none), isNull);
    expect(edgeMultiplicityFromJson('unknown'), EdgeMultiplicity.none);
  });
}
