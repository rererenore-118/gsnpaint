// ログイン中アカウントの図を Cloud Firestore に保存・読み出しするサービス。
//
// 保存先: users/{uid}/diagrams/{ランダムID}
// 名前と本文（図の JSON 文字列。ローカルの「JSON保存」と同じ中身）は {"name", "content"} にまとめて
// ブラウザ内で暗号化してから保存する（CryptoService、設計は docs/encryption-design.md）。
// 平文で残るのは更新日時（updatedAt）だけ。本人以外が読み書きできないことは firestore.rules で保証する。
//
// 版の履歴: users/{uid}/diagrams/{ID}/versions/{ランダムID}
// 上書き保存のたびに、それまでの内容を版として残す（図ごとに新しい順で maxVersions 件まで）。
// 版も同じ形で暗号化し、暗号化のときの「どこのデータか」には版の場所を使う（版どうしの入れ替えも検知する）。

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

/// 図の過去の版（一覧表示用）
class CloudDiagramVersion {
  final String id;
  final DateTime? savedAt; // この版が保存された日時
  const CloudDiagramVersion({required this.id, this.savedAt});
}

class CloudDiagramService {
  /// 図ごとに残す過去の版の数
  static const int maxVersions = 20;

  /// Firestore の1ドキュメントの上限は 1MiB。暗号化すると Base64 で約4/3倍になるので、
  /// 名前と本文を合わせた大きさをこれ以下にする。
  static const int maxContentBytes = 700 * 1000;

  static const String _collection = 'diagrams';

  final CryptoService _crypto;
  CloudDiagramService(this._crypto);

  CollectionReference<Map<String, dynamic>> _diagrams() => _crypto.collection(_collection);

  CollectionReference<Map<String, dynamic>> _versions(String id) =>
      _diagrams().doc(id).collection('versions');

  /// 版を暗号化するときの「どこのデータか」（gsn_crypto.js の AAD に入る）
  static String _versionScope(String id) => '$_collection/$id/versions';

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
    final existingId = await findIdByName(name);
    final id = existingId ?? _diagrams().doc().id;
    final sealed = await _crypto.encrypt(_collection, id, plaintext);
    final batch = _crypto.batch();

    // 上書きのときは、それまでの内容を版として残す（新しい内容と同時に書く）
    if (existingId != null) {
      final current = (await _diagrams().doc(id).get()).data();
      if (current != null && CryptoService.isEncrypted(current)) {
        final versionRef = _versions(id).doc();
        final previous = await _crypto.decrypt(_collection, id, current);
        final sealedVersion = await _crypto.encrypt(_versionScope(id), versionRef.id, previous);
        batch.set(versionRef, {
          ...sealedVersion,
          'updatedAt': current['updatedAt'] ?? FieldValue.serverTimestamp(),
        });
      }
    }
    batch.set(_diagrams().doc(id), {...sealed, 'updatedAt': FieldValue.serverTimestamp()});
    await batch.commit();
    if (existingId != null) await _pruneVersions(id);
  }

  /// 古い版を消して maxVersions 件に収める
  Future<void> _pruneVersions(String id) async {
    final snap = await _versions(id).orderBy('updatedAt', descending: true).get();
    for (final d in snap.docs.skip(maxVersions)) {
      await d.reference.delete();
    }
  }

  /// 過去の版の一覧（新しい順）。版の中身は開くときに復号する
  Future<List<CloudDiagramVersion>> listVersions(String id) async {
    final snap = await _versions(id).orderBy('updatedAt', descending: true).get();
    return snap.docs
        .map((d) => CloudDiagramVersion(
            id: d.id, savedAt: (d.data()['updatedAt'] as Timestamp?)?.toDate()))
        .toList();
  }

  /// 過去の版の図の JSON 文字列を読み出す
  Future<String> loadVersion(String id, String versionId) async {
    final data = (await _versions(id).doc(versionId).get()).data();
    if (data == null) throw StateError('その版が見つかりません。');
    final plain = jsonDecode(await _crypto.decrypt(_versionScope(id), versionId, data))
        as Map<String, dynamic>;
    return plain['content'] as String;
  }

  /// 図の JSON 文字列を読み出す
  Future<String> load(String id) async {
    final data = (await _diagrams().doc(id).get()).data();
    if (data == null) throw StateError('図が見つかりません。');
    return (await _decrypt(id, data))['content'] as String;
  }

  /// 図を削除する（過去の版もすべて消す）
  Future<void> delete(String id) async {
    for (final d in (await _versions(id).get()).docs) {
      await d.reference.delete();
    }
    await _diagrams().doc(id).delete();
  }
}
