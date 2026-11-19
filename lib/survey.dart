// 研究の評価実験で使うアンケートの中身（質問・回答の形・SUS 得点・CSV への書き出し）。
// Firebase に依存しないので、単体でテストできる（test/survey_test.dart）。
//
// 回答は Firestore の surveys/{surveyId}/responses/{uid} に暗号化せずに置き、
// 研究者（admins/{uid} に登録したアカウント）だけが読める（firestore.rules）。
// 質問を変えるときは、firestore.rules の isSurveyAnswers も合わせて変え、
// 前の回答と混ざらないよう [surveyId] の番号を上げる。

/// アンケートの版。回答の置き場所の名前にもなる。
const surveyId = 'editor-eval-v1';

/// 5 段階の答え（1〜5）の意味
const likertLabels = [
  'まったくそう思わない',
  'そう思わない',
  'どちらとも言えない',
  'そう思う',
  'とてもそう思う',
];

/// System Usability Scale（SUS, Brooke 1996）の 10 問。奇数番は肯定、偶数番は否定の文。
const susItems = [
  'このエディタをしばしば使いたいと思う',
  'このエディタは不必要なほど複雑だと思う',
  'このエディタは使いやすいと思う',
  'このエディタを使えるようになるには、技術に詳しい人の助けが必要だと思う',
  'このエディタのいろいろな機能はよくまとまっていると思う',
  'このエディタには一貫性のないところが多すぎると思う',
  'たいていの人は、このエディタの使い方をすぐに覚えると思う',
  'このエディタはとても扱いにくいと思う',
  'このエディタを使いこなせる自信がある',
  'このエディタを使い始める前に、多くのことを学ぶ必要があった',
];

/// 回答者の経験を聞く質問（キー → 選択肢の値 → 画面の文）
const backgroundQuestions = <String, (String, Map<String, String>)>{
  'gsn_exp': (
    'GSN を使った経験',
    {
      'none': 'ない',
      'seen': '見たことがある（講義・論文など）',
      'wrote': '自分で書いたことがある',
    },
  ),
  'prog_exp': (
    'プログラミングの経験',
    {'lt1': '1 年未満', '1to3': '1〜3 年', 'gt3': '3 年以上'},
  ),
};

/// 自由記述（キー → 画面の文）
const freeTextQuestions = {
  'good': '使ってみて良かった点',
  'bad': '使いにくかった点・改善してほしい点',
};

const maxFreeTextLength = 2000;

String susKey(int i) => 'sus${i + 1}';

/// 送信する回答
class SurveyResponse {
  /// 参加者番号。回答者には聞かず、研究者が書き出すときに回答順で振る（[surveyResponsesToCsv]）。
  /// 保存形式（firestore.rules）に合わせて、空の文字列のまま送る。
  final String participantId;

  /// gsn_exp・prog_exp（選択肢の値）、sus1〜sus10（1〜5）、good・bad（文字列）
  final Map<String, Object> answers;

  const SurveyResponse({this.participantId = '', required this.answers});

  /// まだ答えていない必須の質問の数（自由記述は任意）
  static int missingCount(Map<String, Object?> answers) {
    var missing = 0;
    for (final key in backgroundQuestions.keys) {
      if (answers[key] is! String) missing++;
    }
    for (var i = 0; i < susItems.length; i++) {
      if (answers[susKey(i)] is! int) missing++;
    }
    return missing;
  }

  Map<String, Object> toFirestore() => {
    'participantId': participantId,
    'answers': answers,
  };
}

/// SUS 得点（0〜100）。答えがそろっていなければ null。
/// 奇数番は（答え − 1）、偶数番は（5 − 答え）を足して 2.5 倍する。
double? susScore(Map<String, Object?> answers) {
  var sum = 0;
  for (var i = 0; i < susItems.length; i++) {
    final v = answers[susKey(i)];
    if (v is! int || v < 1 || v > 5) return null;
    sum += i.isEven ? v - 1 : 5 - v;
  }
  return sum * 2.5;
}

/// 集めた回答 1 件（研究者が書き出すときに使う）
class StoredSurveyResponse {
  final String respondent;
  final String participantId;
  final DateTime? submittedAt;
  final Map<String, Object?> answers;
  const StoredSurveyResponse({
    required this.respondent,
    required this.participantId,
    required this.submittedAt,
    required this.answers,
  });
}

String _csvField(Object? v) {
  final s = v?.toString() ?? '';
  if (!s.contains(RegExp(r'[",\n\r]'))) return s;
  return '"${s.replaceAll('"', '""')}"';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _formatTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}';
}

/// 参加者番号: 回答日時の順に P001、P002… と振る
String participantNumber(int index) => 'P${(index + 1).toString().padLeft(3, '0')}';

/// 回答を CSV にする（Excel で文字化けしないよう、先頭に BOM を付ける）。
/// 選択肢は画面の文ではなく値（none など）で書き、集計しやすくする。
/// 参加者番号は回答日時の順に振るので、途中の回答を消すと後ろの番号がずれる。
String surveyResponsesToCsv(List<StoredSurveyResponse> responses) {
  final ordered = [...responses]..sort(
    (a, b) => (a.submittedAt ?? DateTime(0)).compareTo(b.submittedAt ?? DateTime(0)),
  );
  final header = [
    '参加者番号',
    '回答者',
    '回答日時',
    ...backgroundQuestions.keys,
    for (var i = 0; i < susItems.length; i++) susKey(i),
    'sus_score',
    ...freeTextQuestions.keys,
  ];
  final rows = [
    for (final (i, r) in ordered.indexed)
      [
        participantNumber(i),
        r.respondent,
        _formatTime(r.submittedAt),
        for (final k in backgroundQuestions.keys) r.answers[k],
        for (var i = 0; i < susItems.length; i++) r.answers[susKey(i)],
        susScore(r.answers),
        for (final k in freeTextQuestions.keys) r.answers[k],
      ],
  ];
  return '﻿${[header, ...rows].map((row) => row.map(_csvField).join(',')).join('\r\n')}\r\n';
}
