// ログイン中アカウントのCSVを Cloud Firestore に保存・読み出しするサービス。
//
// 保存先: users/{uid}/csvFiles/{ドキュメントID}
//   name      : ファイル名（FileListノードの説明欄に書く名前。同じ名前なら上書き）
//   content   : CSVのテキスト（UTF-8）
//   updatedAt : 保存時刻（サーバ時刻）
// 評価のときは、図の FileList ノードが使うCSVの中身をまとめて評価サーバに送る
// （サーバ側にCSVは保存しない）。本人以外が読み書きできないことは firestore.rules で保証する。

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class CloudCsvService {
  /// Firestore の1ドキュメントの上限は 1MiB。名前などの分の余裕を残して本文を制限する。
  static const int maxContentBytes = 1000 * 1000;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _csvFiles() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('ログインしていません。');
    return _db.collection('users').doc(uid).collection('csvFiles');
  }

  /// ファイル名からドキュメントIDを作る。IDには '/' が使えず、'.' と '..' も不可。
  /// 名前とIDを1対1にしておくと、同名ファイルの上書き・名前での取得が1回の読み書きで済む。
  static String _docId(String name) =>
      Uri.encodeComponent(name).replaceAll('.', '%2E');

  /// 自分のCSVのファイル名一覧（名前順）
  Future<List<String>> listNames() async {
    final snap = await _csvFiles().orderBy('name').get();
    return snap.docs.map((d) => d.data()['name'] as String).toList();
  }

  Future<bool> exists(String name) async =>
      (await _csvFiles().doc(_docId(name)).get()).exists;

  /// CSVを保存する（同じ名前なら上書き）
  Future<void> save(String name, String content) async {
    if (utf8.encode(content).length > maxContentBytes) {
      throw StateError('CSVが大きすぎて保存できません（上限 約1MB）。');
    }
    await _csvFiles().doc(_docId(name)).set({
      'name': name,
      'content': content,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// 指定した名前のCSVの中身をまとめて取得する（名前 → 中身）。
  /// 見つからない名前は結果に含めない（呼び出し側で不足を判定する）。
  Future<Map<String, String>> loadContents(Iterable<String> names) async {
    final result = <String, String>{};
    for (final name in names.toSet()) {
      final doc = await _csvFiles().doc(_docId(name)).get();
      final content = doc.data()?['content'];
      if (content is String) result[name] = content;
    }
    return result;
  }
}
