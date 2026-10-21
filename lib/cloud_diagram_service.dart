// ログイン中アカウントの図を Cloud Firestore に保存・読み出しするサービス。
//
// 保存先: users/{uid}/diagrams/{ランダムID}
// 名前と本文（図の JSON 文字列。ローカルの「JSON保存」と同じ中身）は {"name", "content"} にまとめて
// ブラウザ内で暗号化してから保存する（CryptoService、設計は docs/encryption-design.md）。
// 平文で残るのは更新日時（updatedAt）だけ。本人以外が読み書きできないことは firestore.rules で保証する。

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'crypto_service.dart';

/// 一覧表示用の図の情報
class CloudDiagram {
  final String id;
  final String name;
  final DateTime? updatedAt; // 保存直後でサーバ時刻が未確定のときは null

  /// 復号できなかった（改ざんされた・壊れた）データ。開けないが削除はできる
  final bool unreadable;

  const CloudDiagram(
      {required this.id, required this.name, this.updatedAt, this.unreadable = false});
}

class CloudDiagramService {
  /// Firestore の1ドキュメントの上限は 1MiB。暗号化すると Base64 で約4/3倍になるので、
  /// 名前と本文を合わせた大きさをこれ以下にする。
  static const int maxContentBytes = 700 * 1000;

  static const String _collection = 'diagrams';

  final CryptoService _crypto;
  CloudDiagramService(this._crypto);

  CollectionReference<Map<String, dynamic>> _diagrams() => _crypto.collection(_collection);

  Future<Map<String, dynamic>> _decrypt(String id, Map<String, dynamic> data) async =>
      jsonDecode(await _crypto.decrypt(_collection, id, data)) as Map<String, dynamic>;

  /// 自分の図の一覧（更新が新しい順）。名前は暗号化されているので、ここで復号する。
  Future<List<CloudDiagram>> list() async {
    final snap = await _diagrams().orderBy('updatedAt', descending: true).get();
    final result = <CloudDiagram>[];
    for (final d in snap.docs) {
      final data = d.data();
      if (!CryptoService.isEncrypted(data)) continue; // 暗号化前のデータは解除時に暗号化済み
      final updatedAt = (data['updatedAt'] as Timestamp?)?.toDate();
      try {
        final plain = await _decrypt(d.id, data);
        result.add(CloudDiagram(id: d.id, name: plain['name'] as String, updatedAt: updatedAt));
      } on CryptoException {
        result.add(CloudDiagram(
            id: d.id, name: '（読めないデータ）', updatedAt: updatedAt, unreadable: true));
      }
    }
    return result;
  }

  /// 同じ名前の図があればその ID を返す（上書き確認に使う）
  Future<String?> findIdByName(String name) async {
    for (final d in await list()) {
      if (!d.unreadable && d.name == name) return d.id;
    }
    return null;
  }

  /// 図を保存する。同じ名前の図があれば上書きする。
  Future<void> save(String name, String content) async {
    final plaintext = jsonEncode({'name': name, 'content': content});
    // Firestore の文字列は UTF-8 のバイト数で数える（日本語は1文字3バイト）
    if (utf8.encode(plaintext).length > maxContentBytes) {
      throw StateError('図が大きすぎて保存できません（上限 約700KB）。');
    }
    final id = await findIdByName(name) ?? _diagrams().doc().id;
    final sealed = await _crypto.encrypt(_collection, id, plaintext);
    await _diagrams().doc(id).set({...sealed, 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// 図の JSON 文字列を読み出す
  Future<String> load(String id) async {
    final data = (await _diagrams().doc(id).get()).data();
    if (data == null) throw StateError('図が見つかりません。');
    return (await _decrypt(id, data))['content'] as String;
  }

  Future<void> delete(String id) => _diagrams().doc(id).delete();
}
