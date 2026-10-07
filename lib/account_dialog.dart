// エディタのアカウント（Firebase Authentication）のログイン・新規登録ダイアログ。
// メール/パスワードと Google ログインに対応する。ログインしたアカウントは
// エディタ内のクラウド保存（Firestore）に使う。

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// ログイン・新規登録のダイアログ。ログインに成功したら true を返して閉じる。
class AccountDialog extends StatefulWidget {
  const AccountDialog({super.key});

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _auth = FirebaseAuth.instance;

  bool _isRegisterMode = false; // false: ログイン / true: 新規登録
  bool _busy = false; // 通信中は二重送信を防ぐ
  String? _error;
  String? _info;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();

  /// 通信処理を共通の流れ（ボタン無効化・エラー表示）で実行する
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      final message = _authErrorMessage(e.code);
      if (mounted && message != null) setState(() => _error = message);
    } catch (e) {
      if (mounted) setState(() => _error = 'エラーが発生しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() => _run(() async {
        if (_isRegisterMode) {
          final cred = await _auth.createUserWithEmailAndPassword(
              email: _email, password: _passwordController.text);
          // 本人のメールアドレスか確かめるため、確認リンク付きのメールを送る。
          // 確認が済むまでクラウド保存は使えない（firestore.rules でも拒否する）。
          await cred.user?.sendEmailVerification();
        } else {
          await _auth.signInWithEmailAndPassword(
              email: _email, password: _passwordController.text);
        }
        if (mounted) Navigator.of(context).pop(true);
      });

  Future<void> _signInWithGoogle() => _run(() async {
        await _auth.signInWithPopup(GoogleAuthProvider());
        if (mounted) Navigator.of(context).pop(true);
      });

  Future<void> _sendPasswordReset() async {
    if (_email.isEmpty) {
      setState(() {
        _error = '再設定メールの送り先として、メールアドレスを入力してください。';
        _info = null;
      });
      return;
    }
    await _run(() async {
      await _auth.sendPasswordResetEmail(email: _email);
      if (mounted) {
        setState(() => _info = '$_email にパスワード再設定メールを送信しました。');
      }
    });
  }

  /// FirebaseAuthException の code を利用者向けの日本語に変換する。
  /// null を返したものは表示しない（ユーザー自身がポップアップを閉じた場合など）。
  /// 現在の Firebase はメール列挙対策で、存在しないユーザー・パスワード違いの多くを
  /// invalid-credential にまとめて返すため、両者を区別した表示はしない。
  String? _authErrorMessage(String code) {
    switch (code) {
      case 'invalid-email':
        return 'メールアドレスの形式が正しくありません。';
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'メールアドレスかパスワードが違います。';
      case 'email-already-in-use':
        return 'このメールアドレスはすでに登録されています。ログインしてください。';
      case 'weak-password':
        return 'パスワードは6文字以上にしてください。';
      case 'missing-password':
        return 'パスワードを入力してください。';
      case 'user-disabled':
        return 'このアカウントは無効化されています。';
      case 'too-many-requests':
        return '試行回数が多すぎます。しばらく待ってから再度お試しください。';
      case 'network-request-failed':
        return 'ネットワークに接続できませんでした。';
      case 'account-exists-with-different-credential':
        return 'このメールアドレスは別のログイン方法で登録されています。';
      case 'popup-blocked':
        return 'ポップアップがブロックされました。ブラウザの設定で許可してください。';
      case 'popup-closed-by-user':
      case 'cancelled-popup-request':
        return null;
      default:
        return 'ログインに失敗しました（$code）。';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isRegisterMode ? 'アカウントを新規登録' : 'ログイン'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'メールアドレス',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              autofillHints: [
                _isRegisterMode ? AutofillHints.newPassword : AutofillHints.password
              ],
              decoration: InputDecoration(
                labelText: _isRegisterMode ? 'パスワード（6文字以上）' : 'パスワード',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            if (!_isRegisterMode)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _busy ? null : _sendPasswordReset,
                  child: const Text('パスワードを忘れた場合'),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_info != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_info!, style: const TextStyle(color: Colors.green)),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_isRegisterMode ? '登録する' : 'ログイン'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _signInWithGoogle,
              icon: const Icon(Icons.g_mobiledata),
              label: const Text('Google でログイン'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _isRegisterMode = !_isRegisterMode;
                        _error = null;
                        _info = null;
                      }),
              child: Text(_isRegisterMode ? 'ログインに戻る' : 'アカウントを新規登録する'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('閉じる'),
        ),
      ],
    );
  }
}


/// ログイン中のアカウント情報。メールアドレスが未確認なら確認メールの再送と確認状態の更新ができる。
/// 閉じるときに、ログアウトが押されたら true を返す。
class AccountInfoDialog extends StatefulWidget {
  const AccountInfoDialog({super.key});

  @override
  State<AccountInfoDialog> createState() => _AccountInfoDialogState();
}

class _AccountInfoDialogState extends State<AccountInfoDialog> {
  final _auth = FirebaseAuth.instance;
  bool _busy = false;
  String? _error;
  String? _info;

  User? get _user => _auth.currentUser;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _error = e.code == 'too-many-requests'
            ? '短時間に何度も送信されました。しばらく待ってから再送してください。'
            : '失敗しました（${e.code}）。');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'エラーが発生しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() => _run(() async {
        await _user?.sendEmailVerification();
        if (mounted) {
          setState(() => _info = '${_user?.email} に確認メールを再送しました。');
        }
      });

  /// メール内のリンクを押した後の確認状態を取り込む。
  /// 確認済みの情報はログイン用トークンに入っているため、トークンも取り直す
  /// （取り直さないと firestore.rules が未確認のまま扱う）。
  Future<void> _refresh() => _run(() async {
        await _user?.reload();
        if (_user?.emailVerified == true) {
          await _user?.getIdToken(true);
          if (mounted) Navigator.of(context).pop(false);
        } else if (mounted) {
          setState(() => _error = 'まだ確認されていません。メール内のリンクを押してから、もう一度お試しください。');
        }
      });

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final verified = user?.emailVerified ?? false;
    return AlertDialog(
      title: const Text('アカウント'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ログイン中のアカウント'),
            const SizedBox(height: 4),
            SelectableText(user?.email ?? '（メールアドレスなし）',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (verified)
              const Row(children: [
                Icon(Icons.verified, color: Colors.green, size: 18),
                SizedBox(width: 4),
                Text('メールアドレス確認済み'),
              ])
            else ...[
              const Row(children: [
                Icon(Icons.mark_email_unread, color: Colors.orange, size: 18),
                SizedBox(width: 4),
                Text('メールアドレスが未確認です',
                    style: TextStyle(color: Colors.orange)),
              ]),
              const SizedBox(height: 8),
              const Text(
                '登録したアドレスに届いた確認メールのリンクを押してから、'
                '「確認した」を押してください。確認が済むまで、アカウントへの保存・読み出しと'
                'CSVは使えません。\n'
                'メールが届かない場合は、迷惑メールフォルダも確認してください。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(children: [
                FilledButton(
                    onPressed: _busy ? null : _refresh,
                    child: const Text('確認した')),
                const SizedBox(width: 8),
                OutlinedButton(
                    onPressed: _busy ? null : _resend,
                    child: const Text('確認メールを再送')),
              ]),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_info != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_info!, style: const TextStyle(color: Colors.green)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: const Text('閉じる')),
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, true),
            child: const Text('ログアウト')),
      ],
    );
  }
}
