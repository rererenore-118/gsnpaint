// アカウントに保存する図・CSVのエンドツーエンド暗号化（設計は docs/encryption-design.md）。
//
// 暗号の処理は web/crypto/gsn_crypto.js（window.gsnCrypto, WebCrypto）が行い、
// このクラスは鍵の情報（keyring）の読み書きと、解除の状態を受け持つ。
//
// 保存先: users/{uid}/crypto/keyring
//   v, pass{kdf,salt,iter,iv,wrappedMk}, recovery{kdf,salt,iv,wrappedMk},
//   passkeys{<パスキーのID>: {prfSalt,iv,wrappedMk,label,createdAt}}, createdAt, updatedAt
// 暗号化した1件（図・CSV）: v, wrappedDek{iv,ct}, iv, ct, updatedAt

import 'dart:convert';
import 'dart:js_interop';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

@JS('gsnCrypto')
external _GsnCrypto? get _gsnCrypto;

extension type _GsnCrypto._(JSObject _) implements JSObject {
  external JSPromise<JSString> setupKeyring(JSString uid, JSString passphrase);
  external JSPromise<JSString> unlockWithPassphrase(
      JSString uid, JSString keyringJson, JSString passphrase);
  external JSPromise<JSString> unlockWithRecoveryKey(
      JSString uid, JSString keyringJson, JSString recoveryKey);
  external JSPromise<JSString> rewrapPassphrase(
      JSString uid, JSString keyringJson, JSString newPassphrase);
  external JSPromise<JSString> passkeySupported();
  external JSPromise<JSString> registerPasskey(
      JSString uid, JSString keyringJson, JSString userName, JSString label);
  external JSPromise<JSString> unlockWithPasskey(JSString uid, JSString keyringJson);
  external JSPromise<JSString> lock();
  external JSPromise<JSString> encryptItem(
      JSString uid, JSString collection, JSString docId, JSString plaintext);
  external JSPromise<JSString> decryptItem(
      JSString uid, JSString collection, JSString docId, JSString itemJson);
}

/// 暗号化の失敗。code は WRONG_SECRET（パスフレーズ・回復キー違い）、WEAK_PASSPHRASE、
/// LOCKED（未解除）、TAMPERED（改ざん・入れ替え）、BAD_FORMAT、UNAVAILABLE など。
class CryptoException implements Exception {
  final String code;
  final String message;
  const CryptoException(this.code, this.message);

  @override
  String toString() => message;
}

/// 登録済みのパスキー
class PasskeyInfo {
  final String id;
  final String label;
  final DateTime? createdAt;
  const PasskeyInfo(this.id, this.label, this.createdAt);
}

/// 暗号化されていない（暗号化機能より前に保存された）1件
class PlaintextItem {
  final String collection;
  final String id;
  final String name;
  final String content;
  final Timestamp? updatedAt;
  const PlaintextItem(this.collection, this.id, this.name, this.content, this.updatedAt);
}

class CryptoService {
  /// パスフレーズの最低文字数（gsn_crypto.js と同じ）
  static const int minPassphraseLength = 12;

  /// 暗号化の対象のコレクション
  static const List<String> collections = ['diagrams', 'csvFiles'];

  /// 暗号化した1件に含まれる項目（firestore.rules でもこの形だけを許す）
  static const List<String> _itemFields = ['v', 'wrappedDek', 'iv', 'ct'];

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // 解除中のアカウント（鍵そのものは gsn_crypto.js のメモリの中）
  String? _unlockedUid;

  String get _uid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('ログインしていません。');
    return uid;
  }

  DocumentReference<Map<String, dynamic>> get _keyringRef =>
      _db.collection('users').doc(_uid).collection('crypto').doc('keyring');

  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _db.collection('users').doc(_uid).collection(name);

  WriteBatch batch() => _db.batch();

  /// いまのアカウントの鍵が解除されているか
  bool get isUnlocked =>
      _unlockedUid != null && _unlockedUid == FirebaseAuth.instance.currentUser?.uid;

  static _GsnCrypto get _js {
    final js = _gsnCrypto;
    if (js == null) {
      throw const CryptoException('UNAVAILABLE', '暗号化の部品を読み込めませんでした。ページを再読み込みしてください。');
    }
    return js;
  }

  /// gsn_crypto.js の返り値（{"ok":..}）を解釈する
  static Future<Object?> _call(JSPromise<JSString> promise) async {
    final reply = jsonDecode((await promise.toDart).toDart) as Map<String, dynamic>;
    if (reply['ok'] != true) {
      throw CryptoException(reply['code'] as String, reply['message'] as String);
    }
    return reply['value'];
  }

  /// 鍵の情報を JSON にする（Firestore の日時など、暗号に関係ない項目は除く）
  static String _keyringJson(Map<String, dynamic> data) => jsonEncode({
        'v': data['v'],
        'pass': data['pass'],
        'recovery': data['recovery'],
        if (data['passkeys'] != null) 'passkeys': data['passkeys'],
      });

  /// 鍵の情報があるか（初回設定が済んでいるか）
  Future<bool> hasKeyring() async => (await _keyringRef.get()).exists;

  Future<Map<String, dynamic>> _loadKeyring() async {
    final data = (await _keyringRef.get()).data();
    if (data == null) throw const CryptoException('NO_KEYRING', '暗号化の初回設定がまだです。');
    return data;
  }

  /// 初回設定。主鍵と回復キーを作って保存し、解除した状態にする。回復キー（表示用）を返す。
  Future<String> setup(String passphrase) async {
    final uid = _uid;
    final String recoveryKey;
    try {
      final result = jsonDecode(await _call(_js.setupKeyring(uid.toJS, passphrase.toJS)) as String)
          as Map<String, dynamic>;
      final keyring = result['keyring'] as Map<String, dynamic>;
      recoveryKey = result['recoveryKey'] as String;
      // 別のタブなどで先に設定されていたら上書きしない（上書きすると前の鍵のデータが読めなくなる）
      await _db.runTransaction((tx) async {
        if ((await tx.get(_keyringRef)).exists) {
          throw const CryptoException('ALREADY_SET_UP', 'すでに暗号化の設定がされています。パスフレーズで解除してください。');
        }
        tx.set(_keyringRef, {...keyring, 'createdAt': FieldValue.serverTimestamp()});
      });
    } catch (_) {
      // 失敗したら作りかけの鍵を忘れる（保存されていない鍵でデータを暗号化しないため）
      await lock();
      rethrow;
    }
    _unlockedUid = uid;
    return recoveryKey;
  }

  Future<void> unlockWithPassphrase(String passphrase) async {
    final uid = _uid;
    final keyring = await _loadKeyring();
    await _call(_js.unlockWithPassphrase(uid.toJS, _keyringJson(keyring).toJS, passphrase.toJS));
    _unlockedUid = uid;
  }

  /// 回復キーで解除し、新しいパスフレーズを設定する
  Future<void> recoverAndSetPassphrase(String recoveryKey, String newPassphrase) async {
    final uid = _uid;
    final keyring = await _loadKeyring();
    await _call(_js.unlockWithRecoveryKey(uid.toJS, _keyringJson(keyring).toJS, recoveryKey.toJS));
    _unlockedUid = uid;
    await changePassphrase(newPassphrase);
  }

  /// 解除中にパスフレーズを変える（主鍵を包み直すだけで、データは暗号化し直さない）
  Future<void> changePassphrase(String newPassphrase) async {
    final uid = _uid;
    final keyring = await _loadKeyring();
    final updated = jsonDecode(await _call(
            _js.rewrapPassphrase(uid.toJS, _keyringJson(keyring).toJS, newPassphrase.toJS))
        as String) as Map<String, dynamic>;
    await _keyringRef.update({'pass': updated['pass'], 'updatedAt': FieldValue.serverTimestamp()});
  }

  // ---- パスキー ----

  /// このブラウザでパスキーによる解除（WebAuthn の PRF 拡張）を使えそうか
  static Future<bool> passkeySupported() async {
    final js = _gsnCrypto;
    if (js == null) return false;
    try {
      return await _call(js.passkeySupported()) == true;
    } catch (_) {
      return false;
    }
  }

  /// 登録済みのパスキー（新しい順）
  Future<List<PasskeyInfo>> listPasskeys() async {
    final data = (await _keyringRef.get()).data();
    final passkeys = (data?['passkeys'] as Map<String, dynamic>?) ?? {};
    return passkeys.entries.map((e) {
      final v = e.value as Map<String, dynamic>;
      return PasskeyInfo(e.key, v['label'] as String? ?? 'パスキー',
          DateTime.tryParse(v['createdAt'] as String? ?? ''));
    }).toList()
      ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
  }

  /// パスキーを作って登録する（解除中のみ）。端末のパスキーの確認が2回出ることがある。
  Future<void> registerPasskey(String label) async {
    final uid = _uid;
    final keyring = await _loadKeyring();
    final email = FirebaseAuth.instance.currentUser?.email ?? uid;
    final updated = jsonDecode(await _call(_js.registerPasskey(
            uid.toJS, _keyringJson(keyring).toJS, email.toJS, label.toJS)) as String)
        as Map<String, dynamic>;
    await _keyringRef
        .update({'passkeys': updated['passkeys'], 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// 登録済みのパスキーで解除する
  Future<void> unlockWithPasskey() async {
    final uid = _uid;
    final keyring = await _loadKeyring();
    await _call(_js.unlockWithPasskey(uid.toJS, _keyringJson(keyring).toJS));
    _unlockedUid = uid;
  }

  /// パスキーの登録を外す（端末側のパスキー自体は、端末の設定から消してもらう）
  Future<void> removePasskey(String id) async {
    final keyring = await _loadKeyring();
    final passkeys = Map<String, dynamic>.from(keyring['passkeys'] as Map? ?? {})..remove(id);
    await _keyringRef.update({'passkeys': passkeys, 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// 鍵を忘れる（ログアウト・アカウントの切り替え時）
  Future<void> lock() async {
    _unlockedUid = null;
    final js = _gsnCrypto;
    if (js != null) await js.lock().toDart;
  }

  /// 1件を暗号化して Firestore に書く形（updatedAt は呼び出し側で付ける）にする
  Future<Map<String, dynamic>> encrypt(String collection, String docId, String plaintext) async {
    final uid = _uid;
    return jsonDecode(await _call(
            _js.encryptItem(uid.toJS, collection.toJS, docId.toJS, plaintext.toJS)) as String)
        as Map<String, dynamic>;
  }

  /// Firestore の1件を復号して元の文字列を返す
  Future<String> decrypt(String collection, String docId, Map<String, dynamic> data) async {
    final uid = _uid;
    final item = {for (final f in _itemFields) f: data[f]};
    return await _call(_js.decryptItem(
        uid.toJS, collection.toJS, docId.toJS, jsonEncode(item).toJS)) as String;
  }

  /// 暗号化したドキュメントか（暗号化機能より前の平文のドキュメントは content を持つ）
  static bool isEncrypted(Map<String, dynamic> data) => data['ct'] is String;

  /// 暗号化されていない古いデータを探す
  Future<List<PlaintextItem>> findPlaintext() async {
    final items = <PlaintextItem>[];
    for (final col in collections) {
      final snap = await collection(col).get();
      for (final d in snap.docs) {
        final data = d.data();
        if (isEncrypted(data)) continue;
        items.add(PlaintextItem(col, d.id, data['name'] as String? ?? '(名前なし)',
            data['content'] as String? ?? '', data['updatedAt'] as Timestamp?));
      }
    }
    return items;
  }

  /// 古いデータ1件を暗号化して置き換える（新しいIDで書き、古い平文のドキュメントは消す）
  Future<void> encryptPlaintext(PlaintextItem item) async {
    final ref = collection(item.collection).doc();
    final sealed = await encrypt(
        item.collection, ref.id, jsonEncode({'name': item.name, 'content': item.content}));
    final batch = _db.batch()
      ..set(ref, {...sealed, 'updatedAt': item.updatedAt ?? FieldValue.serverTimestamp()})
      ..delete(collection(item.collection).doc(item.id));
    await batch.commit();
  }

  /// パスフレーズも回復キーもないとき: 図・CSV・鍵の情報をすべて消して、初めからやり直せるようにする
  Future<void> deleteAllData() async {
    for (final col in collections) {
      final snap = await collection(col).get();
      for (final d in snap.docs) {
        // 図の過去の版（サブコレクション）は親を消しても残るので、先に消す
        if (col == 'diagrams') {
          for (final v in (await d.reference.collection('versions').get()).docs) {
            await v.reference.delete();
          }
        }
        await d.reference.delete();
      }
    }
    await _keyringRef.delete();
    await lock();
  }
}
