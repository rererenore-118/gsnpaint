// ログイン中アカウントの図を Cloud Firestore に保存・読み出しするサービス。
//
// 保存先: users/{uid}/diagrams/{自動ID}
//   name      : 図の名前（同じ名前で保存すると上書き）
//   content   : 図の JSON 文字列（ローカルの「JSON保存」と同じ中身）
//   updatedAt : 保存時刻（サーバ時刻）
// 本人以外が読み書きできないことは firestore.rules で保証する。

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// 一覧表示用の図の情報
class CloudDiagram {
  final String id;
  final String name;
  final DateTime? updatedAt; // 保存直後でサーバ時刻が未確定のときは null

  const CloudDiagram({required this.id, required this.name, this.updatedAt});
}

class CloudDiagramService {
  /// Firestore の1ドキュメントの上限は 1MiB。名前などの分の余裕を残して本文を制限する。
  static const int maxContentBytes = 1000 * 1000;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _diagrams() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('ログインしていません。');
    return _db.collection('users').doc(uid).collection('diagrams');
  }

  /// 自分の図の一覧（更新が新しい順）
  Future<List<CloudDiagram>> list() async {
    final snap = await _diagrams().orderBy('updatedAt', descending: true).get();
    return snap.docs.map((d) {
      final data = d.data();
      return CloudDiagram(
        id: d.id,
        name: data['name'] as String? ?? '(名前なし)',
        updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      );
    }).toList();
  }

  /// 同じ名前の図があればその ID を返す（上書き確認に使う）
  Future<String?> findIdByName(String name) async {
    final snap =
        await _diagrams().where('name', isEqualTo: name).limit(1).get();
    return snap.docs.isEmpty ? null : snap.docs.first.id;
  }

  /// 図を保存する。同じ名前の図があれば上書きする。
  Future<void> save(String name, String content) async {
    // Firestore の文字列は UTF-8 のバイト数で数える（日本語は1文字3バイト）
    if (utf8.encode(content).length > maxContentBytes) {
      throw StateError('図が大きすぎて保存できません（上限 約1MB）。');
    }
    final data = {
      'name': name,
      'content': content,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    final existingId = await findIdByName(name);
    if (existingId != null) {
      await _diagrams().doc(existingId).set(data);
    } else {
      await _diagrams().add(data);
    }
  }

  /// 図の JSON 文字列を読み出す
  Future<String> load(String id) async {
    final doc = await _diagrams().doc(id).get();
    final content = doc.data()?['content'];
    if (content is! String) throw StateError('図が見つかりません。');
    return content;
  }

  Future<void> delete(String id) => _diagrams().doc(id).delete();
}
