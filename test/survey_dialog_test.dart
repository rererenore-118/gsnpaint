// アンケートのダイアログ（lib/survey_dialog.dart）のテスト。
//   flutter test test/survey_dialog_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/survey.dart';
import 'package:gsnpaint/survey_dialog.dart';

void main() {
  testWidgets('全部答えると送信でき、確認のあとに回答が返る', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final results = <SurveyResponse?>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => results.add(await showDialog<SurveyResponse>(
            context: context,
            builder: (_) => const SurveyDialog(),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    FilledButton submit() => tester.widget(find.widgetWithText(FilledButton, '送信'));
    expect(submit().onPressed, isNull);
    expect(find.text('未回答 12 問'), findsOneWidget);

    expect(find.textContaining('参加者番号'), findsNothing);
    await tester.tap(find.text('自分で書いたことがある'));
    await tester.tap(find.text('3 年以上'));
    for (var i = 0; i < susItems.length; i++) {
      final row = find.byKey(ValueKey(susKey(i)));
      await tester.ensureVisible(row);
      await tester.tap(find.descendant(of: row, matching: find.text(i.isEven ? '4' : '2')));
      await tester.pump();
    }
    await tester.enterText(find.widgetWithText(TextField, '使ってみて良かった点'), '線が見やすい');
    await tester.pumpAndSettle();
    expect(submit().onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, '送信'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '送信'));
    await tester.pumpAndSettle();

    final r = results.single!;
    expect(r.participantId, '');
    expect(r.answers['gsn_exp'], 'wrote');
    expect(r.answers['prog_exp'], 'gt3');
    expect(r.answers['sus1'], 4);
    expect(r.answers['sus2'], 2);
    expect(r.answers['good'], '線が見やすい');
    expect(r.answers['bad'], '');
    expect(susScore(r.answers), 75);
  });
}
