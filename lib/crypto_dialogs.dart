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

  @override
  void dispose() {
    for (final c in [_pass, _recovery, _newPass, _newConfirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
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
          _error = e.code == 'WRONG_SECRET'
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
