// アカウント保存の暗号化に使う画面（初回設定・回復キーの表示・解除・回復・やり直し・移行）。
// アカウントの図・CSVを使う前に ensureUnlocked() を呼ぶ。

import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'crypto_service.dart';

/// アカウントの図・CSVを使える状態（解除済み）にする。使えるなら true。
/// 初回なら設定と既存データの暗号化、2回目以降なら解除を行う。
Future<bool> ensureUnlocked(BuildContext context, CryptoService crypto) async {
  if (crypto.isUnlocked) return true;
  try {
    var needsSetup = !await crypto.hasKeyring();
    if (!needsSetup) {
      if (!context.mounted) return false;
      final result = await showDialog<_UnlockResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UnlockDialog(crypto: crypto),
      );
      if (result == _UnlockResult.reset) {
        needsSetup = true;
      } else if (result != _UnlockResult.unlocked) {
        return false;
      }
    }
    if (needsSetup) {
      if (!context.mounted) return false;
      final recoveryKey = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SetupDialog(crypto: crypto),
      );
      if (recoveryKey == null || !context.mounted) return false;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RecoveryKeyDialog(recoveryKey: recoveryKey),
      );
    }
    // 暗号化機能より前に保存したデータが残っていれば暗号化する（途中で止まった移行の続きも含む）
    final plaintext = await crypto.findPlaintext();
    if (plaintext.isNotEmpty && context.mounted) {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MigrationDialog(crypto: crypto, items: plaintext),
      );
      if (ok != true) return false;
    }
    return crypto.isUnlocked;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('暗号化の準備に失敗しました: $e')));
    }
    return false;
  }
}

enum _UnlockResult { unlocked, reset }

/// パスフレーズ（と確認用）の入力欄
class _PassphraseFields extends StatelessWidget {
  final TextEditingController pass;
  final TextEditingController confirm;
  final String label;
  final VoidCallback onSubmit;
  final bool autofocus;
  const _PassphraseFields(
      {required this.pass,
      required this.confirm,
      required this.label,
      required this.onSubmit,
      this.autofocus = true});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(
        controller: pass,
        obscureText: true,
        autofocus: autofocus,
        decoration: InputDecoration(
          labelText: label,
          helperText: '${CryptoService.minPassphraseLength}文字以上。文章のような長いものがおすすめです。',
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: confirm,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '確認のためもう一度',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (_) => onSubmit(),
      ),
    ]);
  }
}

String? _checkNewPassphrase(String pass, String confirm) {
  if (pass.characters.length < CryptoService.minPassphraseLength) {
    return 'パスフレーズは${CryptoService.minPassphraseLength}文字以上にしてください。';
  }
  if (pass != confirm) return '確認用のパスフレーズが一致しません。';
  return null;
}

/// 鍵の処理（PBKDF2）は1秒近く画面を止めるので、先に「処理中」を描いてから始める
Future<void> _letSpinnerPaint() => Future<void>.delayed(const Duration(milliseconds: 50));

Widget _busyOr(bool busy, Widget child) => busy
    ? const SizedBox(
        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
    : child;

Widget _errorText(String? error) => error == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(error, style: const TextStyle(color: Colors.red)),
      );

// ---- 初回設定 ----

class _SetupDialog extends StatefulWidget {
  final CryptoService crypto;
  const _SetupDialog({required this.crypto});

  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final error = _checkNewPassphrase(_pass.text, _confirm.text);
    if (error != null) return setState(() => _error = error);
    setState(() {
      _busy = true;
      _error = null;
    });
    await _letSpinnerPaint();
    try {
      final recoveryKey = await widget.crypto.setup(_pass.text);
      if (mounted) Navigator.of(context).pop(recoveryKey);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('暗号化パスフレーズの設定'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'アカウントに保存する図とCSVは、このパスフレーズでブラウザ内で暗号化してから保存します。'
            '運営者を含め、本人以外は中身を読めません。\n'
            'ログインのパスワードとは別のものにしてください。',
          ),
          const SizedBox(height: 16),
          _PassphraseFields(
              pass: _pass, confirm: _confirm, label: '暗号化パスフレーズ', onSubmit: _submit),
          _errorText(_error),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('キャンセル')),
        FilledButton(onPressed: _busy ? null : _submit, child: _busyOr(_busy, const Text('設定する'))),
      ],
    );
  }
}

// ---- 回復キーの表示 ----

class _RecoveryKeyDialog extends StatefulWidget {
  final String recoveryKey;
  const _RecoveryKeyDialog({required this.recoveryKey});

  @override
  State<_RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<_RecoveryKeyDialog> {
  bool _saved = false;

  void _download() {
    final text = 'GSNエディタ 回復キー\n\n${widget.recoveryKey}\n\n'
        '暗号化パスフレーズを忘れたときに必要です。他の人に見せないでください。\n';
    final url = html.Url.createObjectUrlFromBlob(html.Blob([utf8.encode(text)]));
    html.AnchorElement(href: url)
      ..setAttribute('download', 'gsn-recovery-key.txt')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('回復キーを控えてください'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'パスフレーズを忘れたときは、この回復キーがないとデータを開けません。'
            '運営者も復旧できません。紙に書くか、ファイルで安全な場所に保存してください。\n'
            'この画面を閉じると、回復キーは二度と表示されません。',
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              borderRadius: BorderRadius.circular(6),
            ),
            // 回復キーは1行で表示する（途中で折り返すと書き写し間違いのもとになる）
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SelectableText(widget.recoveryKey,
                  maxLines: 1,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 1)),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('コピー'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.recoveryKey));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('回復キーをコピーしました。')));
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.download, size: 18),
              label: const Text('テキストで保存'),
              onPressed: _download,
            ),
          ]),
          CheckboxListTile(
            value: _saved,
            onChanged: (v) => setState(() => _saved = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('回復キーを安全な場所に控えました'),
          ),
        ]),
      ),
      actions: [
        FilledButton(
            onPressed: _saved ? () => Navigator.of(context).pop() : null,
            child: const Text('完了')),
      ],
    );
  }
}

// ---- 解除（パスフレーズ／回復キー／やり直し）----

enum _UnlockMode { passphrase, recovery }

class _UnlockDialog extends StatefulWidget {
  final CryptoService crypto;
  const _UnlockDialog({required this.crypto});

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  _UnlockMode _mode = _UnlockMode.passphrase;
  final _pass = TextEditingController();
  final _recovery = TextEditingController();
  final _newPass = TextEditingController();
  final _newConfirm = TextEditingController();
  bool _busy = false;
  String? _error;
  // 登録済みのパスキーがあり、このブラウザで使えそうなら「パスキーで解除」を出す
  bool _passkeyAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkPasskey();
  }

  Future<void> _checkPasskey() async {
    try {
      final available = await CryptoService.passkeySupported() &&
          (await widget.crypto.listPasskeys()).isNotEmpty;
      if (mounted) setState(() => _passkeyAvailable = available);
    } catch (_) {
      // パスキーが使えなくてもパスフレーズで解除できる
    }
  }

  void _unlockWithPasskey() => _run(widget.crypto.unlockWithPasskey, passkey: true);

  @override
  void dispose() {
    for (final c in [_pass, _recovery, _newPass, _newConfirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, {bool passkey = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await _letSpinnerPaint();
    try {
      await action();
      if (mounted) Navigator.of(context).pop(_UnlockResult.unlocked);
    } on CryptoException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = passkey
              ? (e.code == 'WRONG_SECRET'
                  ? 'このパスキーでは解除できませんでした。パスフレーズで解除してください。'
                  : e.message)
              : e.code == 'WRONG_SECRET'
                  ? (_mode == _UnlockMode.passphrase ? 'パスフレーズが違います。' : '回復キーが違います。')
                  : e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  void _submit() {
    if (_mode == _UnlockMode.passphrase) {
      if (_pass.text.isEmpty) return;
      _run(() => widget.crypto.unlockWithPassphrase(_pass.text));
    } else {
      final error = _checkNewPassphrase(_newPass.text, _newConfirm.text);
      if (_recovery.text.trim().isEmpty) {
        return setState(() => _error = '回復キーを入力してください。');
      }
      if (error != null) return setState(() => _error = error);
      _run(() => widget.crypto.recoverAndSetPassphrase(_recovery.text, _newPass.text));
    }
  }

  Future<void> _confirmReset() async {
    final reset = await showDialog<bool>(
      context: context,
      builder: (_) => _ResetDialog(crypto: widget.crypto),
    );
    if (reset == true && mounted) Navigator.of(context).pop(_UnlockResult.reset);
  }

  @override
  Widget build(BuildContext context) {
    final recovering = _mode == _UnlockMode.recovery;
    return AlertDialog(
      title: Text(recovering ? '回復キーで解除' : '暗号化の解除'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!recovering) ...[
            const Text('アカウントの図とCSVを開くには、暗号化パスフレーズを入力してください。'),
            if (_passkeyAvailable) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('パスキーで解除'),
                  onPressed: _busy ? null : _unlockWithPasskey,
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: Text('または', style: TextStyle(color: Colors.grey))),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _pass,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: '暗号化パスフレーズ', border: OutlineInputBorder(), isDense: true),
              onSubmitted: (_) => _submit(),
            ),
          ] else ...[
            const Text('回復キーを入力し、新しい暗号化パスフレーズを設定してください。'),
            const SizedBox(height: 16),
            TextField(
              controller: _recovery,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: '回復キー（XXXX-XXXX-…）', border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 12),
            _PassphraseFields(
                pass: _newPass,
                confirm: _newConfirm,
                label: '新しい暗号化パスフレーズ',
                onSubmit: _submit,
                autofocus: false), // 先に回復キーを入力してもらう
          ],
          _errorText(_error),
          const SizedBox(height: 8),
          if (!recovering)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _mode = _UnlockMode.recovery;
                        _error = null;
                      }),
              child: const Text('パスフレーズを忘れた（回復キーを使う）'),
            )
          else
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _mode = _UnlockMode.passphrase;
                        _error = null;
                      }),
              child: const Text('パスフレーズで解除する'),
            ),
          TextButton(
            onPressed: _busy ? null : _confirmReset,
            child: const Text('パスフレーズも回復キーもない'),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('キャンセル')),
        FilledButton(onPressed: _busy ? null : _submit, child: _busyOr(_busy, const Text('解除'))),
      ],
    );
  }
}

// ---- やり直し（全データの削除）----

class _ResetDialog extends StatefulWidget {
  final CryptoService crypto;
  const _ResetDialog({required this.crypto});

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  static const _confirmWord = '削除する';
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.crypto.deleteAllData();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '削除に失敗しました: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('データを削除して初めからやり直す'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'パスフレーズと回復キーの両方がない場合、アカウントに保存した図とCSVは誰にも開けません（運営者も復旧できません）。\n'
            '続けると、アカウントの図とCSVをすべて削除し、新しいパスフレーズを設定し直します。元に戻せません。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _confirm,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: '確認のため「$_confirmWord」と入力', border: OutlineInputBorder(), isDense: true),
          ),
          _errorText(_error),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('キャンセル')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: _busy || _confirm.text.trim() != _confirmWord ? null : _reset,
          child: _busyOr(_busy, const Text('すべて削除')),
        ),
      ],
    );
  }
}

// ---- 暗号化されていない既存データの暗号化 ----

class _MigrationDialog extends StatefulWidget {
  final CryptoService crypto;
  final List<PlaintextItem> items;
  const _MigrationDialog({required this.crypto, required this.items});

  @override
  State<_MigrationDialog> createState() => _MigrationDialogState();
}

class _MigrationDialogState extends State<_MigrationDialog> {
  int _done = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _migrate();
  }

  Future<void> _migrate() async {
    try {
      for (final item in widget.items) {
        await widget.crypto.encryptPlaintext(item);
        if (mounted) setState(() => _done++);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;
    return AlertDialog(
      title: const Text('保存済みのデータを暗号化しています'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$_done / $total 件'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: total == 0 ? null : _done / total),
          if (_error != null) ...[
            _errorText('途中で失敗しました。次にアカウントの図・CSVを使うときに続きから再開します。\n$_error'),
          ],
        ]),
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('閉じる')),
      ],
    );
  }
}

// ---- 暗号化の設定（パスキーの登録・削除、パスフレーズの変更）----

/// 解除済みのときに開く。呼び出し側で先に ensureUnlocked() を済ませておく。
class CryptoSettingsDialog extends StatefulWidget {
  final CryptoService crypto;
  const CryptoSettingsDialog({super.key, required this.crypto});

  @override
  State<CryptoSettingsDialog> createState() => _CryptoSettingsDialogState();
}

class _CryptoSettingsDialogState extends State<CryptoSettingsDialog> {
  List<PasskeyInfo>? _passkeys;
  bool _supported = false;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final supported = await CryptoService.passkeySupported();
      final passkeys = await widget.crypto.listPasskeys();
      if (mounted) {
        setState(() {
          _supported = supported;
          _passkeys = passkeys;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '読み込みに失敗しました: $e');
    }
  }

  Future<void> _run(Future<void> Function() action, String doneMessage) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await action();
      await _reload();
      if (mounted) setState(() => _info = doneMessage);
    } on CryptoException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPasskey() async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => const _PasskeyLabelDialog(),
    );
    if (label == null) return;
    await _run(() => widget.crypto.registerPasskey(label), 'パスキー「$label」を登録しました。');
  }

  Future<void> _removePasskey(PasskeyInfo p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('パスキーの登録を外す'),
        content: Text('「${p.label}」では解除できなくなります（パスフレーズ・回復キーはそのまま使えます）。\n'
            '端末に残るパスキー自体は、端末やパスワード管理アプリの設定から削除してください。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('外す', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.crypto.removePasskey(p.id), '「${p.label}」の登録を外しました。');
  }

  Future<void> _changePassphrase() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePassphraseDialog(crypto: widget.crypto),
    );
    if (changed == true && mounted) setState(() => _info = '暗号化パスフレーズを変更しました。');
  }

  static String _formatDate(DateTime? t) => t == null
      ? ''
      : '${t.toLocal().year}/${t.toLocal().month}/${t.toLocal().day} 登録';

  @override
  Widget build(BuildContext context) {
    final passkeys = _passkeys;
    return AlertDialog(
      title: const Text('暗号化の設定'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('パスキー', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            '指紋・顔認証などのパスキーで、パスフレーズを入力せずに解除できます。'
            'パスキーを登録しても、パスフレーズと回復キーはそのまま使えます。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (passkeys == null)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          else ...[
            if (passkeys.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('登録済みのパスキーはありません。', style: TextStyle(color: Colors.grey)),
              ),
            for (final p in passkeys)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.fingerprint),
                title: Text(p.label),
                subtitle: Text(_formatDate(p.createdAt)),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '登録を外す',
                  onPressed: _busy ? null : () => _removePasskey(p),
                ),
              ),
            if (_supported)
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('この端末のパスキーを追加'),
                onPressed: _busy ? null : _addPasskey,
              )
            else
              const Text('このブラウザではパスキーを使えません。',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
          ],
          const Divider(height: 32),
          const Text('暗号化パスフレーズ', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _changePassphrase,
            child: const Text('パスフレーズを変更'),
          ),
          if (_busy)
            const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          _errorText(_error),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_info!, style: const TextStyle(color: Colors.green)),
            ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('閉じる')),
      ],
    );
  }
}

/// パスキーの名前（どの端末のものか分かるように）を聞く
class _PasskeyLabelDialog extends StatefulWidget {
  const _PasskeyLabelDialog();

  @override
  State<_PasskeyLabelDialog> createState() => _PasskeyLabelDialogState();
}

class _PasskeyLabelDialogState extends State<_PasskeyLabelDialog> {
  final _label = TextEditingController(text: 'この端末');

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isNotEmpty) Navigator.of(context).pop(label);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('パスキーを追加'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _label,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'パスキーの名前（例: 研究室のMac）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          const Text('このあと端末のパスキーの確認（指紋・顔など）が2回表示されることがあります。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('キャンセル')),
        FilledButton(onPressed: _submit, child: const Text('次へ')),
      ],
    );
  }
}

/// パスフレーズの変更（解除中なので、今のパスフレーズは聞かない）
class _ChangePassphraseDialog extends StatefulWidget {
  final CryptoService crypto;
  const _ChangePassphraseDialog({required this.crypto});

  @override
  State<_ChangePassphraseDialog> createState() => _ChangePassphraseDialogState();
}

class _ChangePassphraseDialogState extends State<_ChangePassphraseDialog> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final error = _checkNewPassphrase(_pass.text, _confirm.text);
    if (error != null) return setState(() => _error = error);
    setState(() {
      _busy = true;
      _error = null;
    });
    await _letSpinnerPaint();
    try {
      await widget.crypto.changePassphrase(_pass.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('パスフレーズを変更'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _PassphraseFields(
              pass: _pass, confirm: _confirm, label: '新しい暗号化パスフレーズ', onSubmit: _submit),
          _errorText(_error),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('キャンセル')),
        FilledButton(onPressed: _busy ? null : _submit, child: _busyOr(_busy, const Text('変更'))),
      ],
    );
  }
}
