// 左のノードパレットのグループを畳む／開くテスト。
// main.dart が dart:html を使うので、ブラウザで動かす:
//   flutter test --platform chrome test/palette_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> showPalette(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: GsnPalette())),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('見出しを押すとそのグループだけ畳まれ、もう一度押すと開く', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await showPalette(tester);
    expect(find.text('Lambda'), findsOneWidget);
    expect(find.text('Goal'), findsOneWidget);

    await tester.ensureVisible(find.text('λ 計算'));
    await tester.tap(find.text('λ 計算'));
    await tester.pumpAndSettle();
    expect(find.text('Lambda'), findsNothing);
    expect(find.text('Goal'), findsOneWidget);
    expect(find.text('λ 計算'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(GsnPalette.prefsKey), ['λ 計算']);

    await tester.ensureVisible(find.text('λ 計算'));
    await tester.tap(find.text('λ 計算'));
    await tester.pumpAndSettle();
    expect(find.text('Lambda'), findsOneWidget);
    expect(prefs.getStringList(GsnPalette.prefsKey), isEmpty);
  });

  testWidgets('前に畳んだグループは畳んだまま開く', (tester) async {
    SharedPreferences.setMockInitialValues({
      GsnPalette.prefsKey: ['GSN', 'レコード'],
    });
    await showPalette(tester);
    expect(find.text('Goal'), findsNothing);
    expect(find.text('Record'), findsNothing);
    expect(find.text('Lambda'), findsOneWidget);
  });
}
