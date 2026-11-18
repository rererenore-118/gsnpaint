// ノードの編集ダイアログのテスト。
//   flutter test test/node_edit_dialog_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/node_edit_dialog.dart';
import 'package:gsnpaint/edge_edit_dialog.dart';

/// ダイアログを開き、閉じたときの結果を results に入れる。
Future<List<NodeEditResult?>> open(WidgetTester tester, NodeEditDialog dialog) async {
  final results = <NodeEditResult?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          results.add(await showDialog<NodeEditResult>(
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

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
}

Finder get referenceBox => find.widgetWithText(FilterChip, '別の図を参照');

void main() {
  testWidgets('普通の Goal を Away にして参照先を入れられる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
        typeName: 'Goal',
        initialLabel: 'SW は安全である',
        initialIsPublic: true,
        initialIsUndeveloped: true,
        canReference: true,
        canBePublic: true,
        canBeUndeveloped: true,
      ),
    );
    expect(find.text('ノード名編集'), findsOneWidget);
    expect(find.text('参照先のモジュール名'), findsNothing);

    await tester.tap(referenceBox);
    await tester.pumpAndSettle();
    expect(find.text('Away Goal の編集'), findsOneWidget);
    expect(find.text('公開'), findsNothing);
    expect(find.text('未展開'), findsNothing);

    await tester.enterText(find.byType(TextField).at(1), '  Away例_SW ');
    await save(tester);

    final r = results.single!;
    expect(r.label, 'SW は安全である');
    expect(r.isAway, isTrue);
    expect(r.module, 'Away例_SW');
    expect(r.isPublic, isFalse);
    expect(r.isUndeveloped, isFalse);
  });

  testWidgets('Away を外すと普通の要素に戻り、参照先は消える', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
        typeName: 'Goal',
        initialLabel: 'SW は安全である',
        initialModule: 'Away例_SW',
        initialIsAway: true,
        canReference: true,
        canBePublic: true,
        canBeUndeveloped: true,
      ),
    );
    expect(find.text('Away Goal の編集'), findsOneWidget);
    expect(find.text('Away例_SW'), findsOneWidget);

    await tester.tap(referenceBox);
    await tester.pumpAndSettle();
    expect(find.text('公開'), findsOneWidget);
    await save(tester);

    final r = results.single!;
    expect(r.isAway, isFalse);
    expect(r.module, '');
    expect(r.label, 'SW は安全である');
  });

  testWidgets('理由があるときは Away にできない', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
        typeName: 'Goal',
        initialLabel: 'G',
        canReference: true,
        referenceBlockedReason: '子があります',
      ),
    );
    expect(find.text('子があります'), findsOneWidget);
    await tester.tap(referenceBox);
    await tester.pumpAndSettle();
    expect(find.text('参照先のモジュール名'), findsNothing);
    await save(tester);
    expect(results.single!.isAway, isFalse);
  });

  testWidgets('すでに Away なら、理由があっても外せる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
        typeName: 'Goal',
        initialLabel: 'G',
        initialIsAway: true,
        canReference: true,
        referenceBlockedReason: '子があります',
      ),
    );
    expect(find.text('子があります'), findsNothing);
    await tester.tap(referenceBox);
    await tester.pumpAndSettle();
    await save(tester);
    expect(results.single!.isAway, isFalse);
  });

  testWidgets('参照先と説明文を一覧から選べる', (tester) async {
    String? askedModule;
    final results = await open(
      tester,
      NodeEditDialog(
        typeName: 'Evidence',
        initialLabel: '仮',
        initialIsAway: true,
        canReference: true,
        pickModule: () async => 'Away例_試験',
        pickClaim: (module) async {
          askedModule = module;
          return '統合試験報告書';
        },
      ),
    );
    expect(find.text('説明（参照先の Evidence と同じ文面）'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.folder_special));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.list));
    await tester.pumpAndSettle();
    await save(tester);

    expect(askedModule, 'Away例_試験');
    expect(results.single!.label, '統合試験報告書');
    expect(results.single!.module, 'Away例_試験');
  });

  testWidgets('参照できない種類には切り替えの欄を出さない', (tester) async {
    await open(tester, const NodeEditDialog(typeName: 'Strategy', initialLabel: 'S'));
    expect(find.byType(FilterChip), findsNothing);
  });

  testWidgets('説明文が空なら保存しない', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(typeName: 'Goal', initialLabel: 'G', canReference: true),
    );
    await tester.enterText(find.byType(TextField).first, '');
    await save(tester);
    expect(results.single, isNull);
  });

  testWidgets('Module Reference は参照先の欄を常に出し、切り替えの欄は出さない', (tester) async {
    final results = await open(
      tester,
      NodeEditDialog(
        typeName: 'Module Reference',
        initialLabel: '',
        isModuleReference: true,
        pickModule: () async => 'HW',
      ),
    );
    expect(find.text('Module Reference の編集'), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byIcon(Icons.list), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'HW の論証');
    await tester.tap(find.byIcon(Icons.folder_special));
    await tester.pumpAndSettle();
    await save(tester);
    final r = results.single!;
    expect(r.label, 'HW の論証');
    expect(r.isAway, isTrue);
    expect(r.module, 'HW');
    expect(r.isPublic, isFalse);
  });

  testWidgets('Choice を付けて注記を入れられる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
          typeName: 'Goal', initialLabel: 'G1', canBeUndeveloped: true, canChoose: true),
    );
    await tester.tap(find.widgetWithText(FilterChip, '選択（Choice）'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '選択の注記（任意）'), '1 of 3');
    await save(tester);
    expect(results.single!.choice, '1 of 3');
  });

  testWidgets('Choice を外すと null になる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
          typeName: 'Goal', initialLabel: 'G1', canChoose: true, initialChoice: ''),
    );
    await tester.tap(find.widgetWithText(FilterChip, '選択（Choice）'));
    await tester.pumpAndSettle();
    await save(tester);
    expect(results.single!.choice, isNull);
  });

  testWidgets('「契約で支える予定」と「未展開」は片方しか付かない', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
          typeName: 'Goal',
          initialLabel: 'G1',
          canBeUndeveloped: true,
          canBeContractPending: true,
          initialIsUndeveloped: true),
    );
    await tester.tap(find.widgetWithText(FilterChip, '契約で支える予定'));
    await tester.pumpAndSettle();
    await save(tester);
    expect(results.single!.contractPending, isTrue);
    expect(results.single!.isUndeveloped, isFalse);
  });

  testWidgets('Evidence に ACP を付けられる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(typeName: 'Evidence', initialLabel: 'E1', canHaveAcp: true),
    );
    await tester.enterText(find.widgetWithText(TextField, 'ACP（任意）'), 'ACP2');
    await save(tester);
    expect(results.single!.acp, 'ACP2');
  });

  testWidgets('Choice の幹に黒丸と個数を付けられる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
          typeName: 'Goal', initialLabel: 'G1', canChoose: true, initialChoice: '1 of 3'),
    );
    await tester.tap(find.text('なし'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('複数（●）').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '選択全体の個数（任意）'), 'n');
    await save(tester);
    expect(results.single!.choiceMultiplicity, EdgeMultiplicity.many);
    expect(results.single!.choiceCardinality, 'n');
  });

  testWidgets('Module Reference などは説明が空でも保存できる', (tester) async {
    final results = await open(
      tester,
      const NodeEditDialog(
          typeName: 'Module', initialLabel: '', isModuleReference: true,
          moduleFieldLabel: 'モジュール名'),
    );
    expect(find.text('Module の編集'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'モジュール名'), 'M1');
    await save(tester);
    expect(results.single!.module, 'M1');
  });
}
