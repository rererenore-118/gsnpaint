// アンケートの中身（lib/survey.dart）のテスト。
//   flutter test test/survey_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:gsnpaint/survey.dart';

Map<String, Object> answers(List<int> sus) => {
  'gsn_exp': 'seen',
  'prog_exp': '1to3',
  for (var i = 0; i < sus.length; i++) susKey(i): sus[i],
  'good': '',
  'bad': '',
};

void main() {
  test('SUS 得点: 奇数番は（答え−1）、偶数番は（5−答え）の合計の 2.5 倍', () {
    expect(susScore(answers(List.filled(10, 3))), 50);
    expect(susScore(answers([5, 1, 5, 1, 5, 1, 5, 1, 5, 1])), 100);
    expect(susScore(answers([1, 5, 1, 5, 1, 5, 1, 5, 1, 5])), 0);
    expect(susScore(answers([4, 2, 4, 1, 4, 2, 5, 2, 4, 3])), 77.5);
    expect(susScore(answers([3, 3, 3])), isNull);
  });

  test('未回答の数は経験の 2 問と SUS の 10 問だけ数える（自由記述は任意）', () {
    expect(SurveyResponse.missingCount({}), 12);
    expect(SurveyResponse.missingCount(answers(List.filled(10, 3))), 0);
    expect(SurveyResponse.missingCount(answers(List.filled(9, 3))), 1);
  });

  test('CSV: BOM 付き、見出しの後に 1 行 1 回答、カンマや改行は引用符で囲む', () {
    final csv = surveyResponsesToCsv([
      StoredSurveyResponse(
        respondent: 'uid1',
        participantId: '',
        submittedAt: DateTime(2026, 11, 19, 9, 5),
        answers: {
          ...answers(List.filled(10, 3)),
          'good': '見やすい, 速い',
          'bad': '1行目\n"2行目"',
        },
      ),
    ]);
    expect(csv.startsWith('﻿参加者番号,回答者,回答日時,gsn_exp,prog_exp,sus1,'), isTrue);
    final lines = csv.substring(1).split('\r\n');
    expect(lines[0].endsWith('sus10,sus_score,good,bad'), isTrue);
    expect(
      lines[1],
      'P001,uid1,2026-11-19 09:05,seen,1to3,3,3,3,3,3,3,3,3,3,3,50.0,'
      '"見やすい, 速い","1行目\n""2行目"""',
    );
  });

  test('参加者番号は回答者に聞かず、回答日時の順に P001 から振る', () {
    StoredSurveyResponse r(String uid, int day) => StoredSurveyResponse(
      respondent: uid,
      participantId: '',
      submittedAt: DateTime(2026, 12, day),
      answers: answers(List.filled(10, 3)),
    );
    final lines = surveyResponsesToCsv([r('c', 3), r('a', 1), r('b', 2)])
        .substring(1)
        .split('\r\n');
    expect(lines.sublist(1, 4).map((l) => l.split(',').take(2).join(',')),
        ['P001,a', 'P002,b', 'P003,c']);
  });
}
