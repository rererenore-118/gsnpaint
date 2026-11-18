// 図の設定（契約モジュール・説明・パターン定義）のテスト。
//   flutter test test/diagram_settings_dialog_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/diagram_settings_dialog.dart';

void main() {
  test('何も設定しなければ保存形式に書かない', () {
    expect(DiagramInfo().toJson(), isNull);
    expect(DiagramInfo.fromJson(null).kind, DiagramKind.argument);
  });

  test('保存形式と行き来できる', () {
    final info = DiagramInfo(
        kind: DiagramKind.contract,
        description: '説明',
        pattern: {'name': 'P', 'intent': ''});
    final json = info.toJson()!;
    expect(json, {
      'kind': 'contract',
      'description': '説明',
      'pattern': {'name': 'P'},
    });
    final back = DiagramInfo.fromJson(json);
    expect(back.isContract, isTrue);
    expect(back.description, '説明');
    expect(back.pattern, {'name': 'P'});
  });

  testWidgets('契約モジュールに切り替えて、パターンの名前を書ける', (tester) async {
    final results = <DiagramInfo?>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => results.add(await showDialog<DiagramInfo>(
            context: context,
            builder: (_) => DiagramSettingsDialog(
                initial: DiagramInfo(), contractViolations: 2),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('使えない要素や印が 2 個'), findsNothing);
    await tester.tap(find.text('契約モジュール'));
    await tester.pumpAndSettle();
    expect(find.textContaining('使えない要素や印が 2 個'), findsOneWidget);
    await tester.tap(find.text('パターン定義を書く'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '名前（別名）'), 'ハザード回避');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(results.single!.isContract, isTrue);
    expect(results.single!.pattern, {'name': 'ハザード回避'});
  });
}
