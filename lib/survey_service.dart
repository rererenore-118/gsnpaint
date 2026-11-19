// 評価実験のアンケートの回答を Firestore に置く・読むサービス。
//
// 保存先: surveys/{surveyId}/responses/{uid}
//   研究者が集計できるよう、図や CSV と違って暗号化しない。メールアドレスは保存せず、
//   アカウントの番号（uid）を文書の名前にして 1 人 1 回答にする。書き換えはできない。
// 研究者: admins/{uid} に文書があるアカウント（Firebase コンソールで作る）だけが、
//   全員の回答を読める（firestore.rules）。
import 'package:cloud_firestore/cloud_firestore.dart';

import 'survey.dart';

class SurveyService {
  final FirebaseFirestore _db;
  SurveyService([FirebaseFirestore? db]) : _db = db ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _responses =>
      _db.collection('surveys').doc(surveyId).collection('responses');

  /// このアカウントがもう答えたか
  Future<bool> hasAnswered(String uid) async =>
      (await _responses.doc(uid).get()).exists;

  /// 回答を送る（1 回だけ。2 回目はルールで断られる）
  Future<void> submit(String uid, SurveyResponse response) =>
      _responses.doc(uid).set({
        ...response.toFirestore(),
        'submittedAt': FieldValue.serverTimestamp(),
      });

  /// 研究者として登録されたアカウントか
  Future<bool> isAdmin(String uid) async {
    try {
      return (await _db.collection('admins').doc(uid).get()).exists;
    } on FirebaseException {
      return false;
    }
  }

  /// 全員の回答（研究者だけ読める）。回答日時の順。
  Future<List<StoredSurveyResponse>> listAll() async {
    final snap = await _responses.get();
    final result = [
      for (final d in snap.docs)
        StoredSurveyResponse(
          respondent: d.id,
          participantId: d.data()['participantId'] as String? ?? '',
          submittedAt: (d.data()['submittedAt'] as Timestamp?)?.toDate(),
          answers: Map<String, Object?>.from(
            d.data()['answers'] as Map? ?? const {},
          ),
        ),
    ];
    result.sort(
      (a, b) => (a.submittedAt ?? DateTime(0)).compareTo(
        b.submittedAt ?? DateTime(0),
      ),
    );
    return result;
  }
}
