// ログイン中アカウントのCSVを Cloud Firestore に保存・読み出しするサービス。
//
// 保存先: users/{uid}/csvFiles/{ランダムID}
// ファイル名（FileListノードの説明欄に書く名前。同じ名前なら上書き）とCSVのテキスト（UTF-8）は
// {"name", "content"} にまとめてブラウザ内で暗号化してから保存する（CryptoService）。
// ファイル名も暗号化するので、名前での検索は一覧を復号してブラウザ内で行う。
// 評価のときは、図の FileList ノードが使うCSVの中身をまとめてブラウザ内の評価に渡す。

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'crypto_service.dart';

class _CsvEntry {
  final String id;
  final String name;
  final String content;
  const _CsvEntry(this.id, this.name, this.content);
}

class CloudCsvService {
  /// 暗号化すると Base64 で約4/3倍になるので、Firestore の1ドキュメントの上限（1MiB）に収まる大きさにする
  static const int maxContentBytes = 700 * 1000;

  static const String _collection = 'csvFiles';

  final CryptoService _crypto;
  CloudCsvService(this._crypto);

  CollectionReference<Map<String, dynamic>> _csvFiles() => _crypto.collection(_collection);

  /// 自分のCSVをすべて復号して返す（復号できないものは除く）
  Future<List<_CsvEntry>> _entries() async {
    final snap = await _csvFiles().get();
    final result = <_CsvEntry>[];
    for (final d in snap.docs) {
      if (!CryptoService.isEncrypted(d.data())) continue;
      try {
        final plain = jsonDecode(await _crypto.decrypt(_collection, d.id, d.data()))
            as Map<String, dynamic>;
        result.add(_CsvEntry(d.id, plain['name'] as String, plain['content'] as String));
      } on CryptoException {
        // 改ざん・破損したデータは使わない
      }
    }
    return result;
  }

  /// 自分のCSVのファイル名一覧（名前順）
  Future<List<String>> listNames() async =>
      (await _entries()).map((e) => e.name).toList()..sort();

  Future<bool> exists(String name) async =>
      (await _entries()).any((e) => e.name == name);

  /// CSVを保存する（同じ名前なら上書き）
  Future<void> save(String name, String content) async {
    final plaintext = jsonEncode({'name': name, 'content': content});
    if (utf8.encode(plaintext).length > maxContentBytes) {
      throw StateError('CSVが大きすぎて保存できません（上限 約700KB）。');
    }
    String? id;
    for (final e in await _entries()) {
      if (e.name == name) id = e.id;
    }
    id ??= _csvFiles().doc().id;
    final sealed = await _crypto.encrypt(_collection, id, plaintext);
    await _csvFiles().doc(id).set({...sealed, 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// 指定した名前のCSVの中身をまとめて取得する（名前 → 中身）。
  /// 見つからない名前は結果に含めない（呼び出し側で不足を判定する）。
  Future<Map<String, String>> loadContents(Iterable<String> names) async {
    final wanted = names.toSet();
    return {
      for (final e in await _entries())
        if (wanted.contains(e.name)) e.name: e.content,
    };
  }
}
