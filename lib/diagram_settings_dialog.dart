// 図そのものの設定: 図の種類（普通の論証モジュールか契約モジュールか、GSN v3 1:4.7）、
// モジュールの説明（モジュールインタフェースに載る、1:4.6.3）、パターン定義（1:3.4）。
// main.dart は dart:html と Firebase に依存するので、単体でテストできるよう分けている
// （test/diagram_settings_dialog_test.dart）。
import 'package:flutter/material.dart';

/// 図の種類
enum DiagramKind {
  /// 普通の論証モジュール
  argument,

  /// 契約モジュール（1:4.7）: モジュールのインタフェースどうしの関係を定める。
  /// Away Goal を支えてよい代わりに、公開・Module Reference・Contract Reference・
  /// 「契約で支える予定」は使えない。
  contract,
}

/// パターン定義（1:3.4）の項目。キーは保存形式、値は画面の見出し。
const patternFields = {
  'name': '名前（別名）',
  'intent': '意図',
  'motivation': '動機',
  'structure': '構造',
  'participants': '参加要素',
  'collaboration': '協調',
  'applicability': '適用条件',
  'consequences': '結果',
  'implementation': '実装',
  'examples': '例',
  'known_uses': '既知の使用例',
  'related_patterns': '関連パターン',
};

class DiagramInfo {
  DiagramKind kind;
  String description;
  Map<String, String> pattern;

  DiagramInfo({
    this.kind = DiagramKind.argument,
    this.description = '',
    Map<String, String>? pattern,
  }) : pattern = pattern ?? {};

  bool get isContract => kind == DiagramKind.contract;

  bool get isEmpty =>
      kind == DiagramKind.argument &&
      description.isEmpty &&
      pattern.values.every((v) => v.isEmpty);

  factory DiagramInfo.fromJson(Object? json) {
    if (json is! Map) return DiagramInfo();
    final pattern = json['pattern'];
    return DiagramInfo(
      kind:
          json['kind'] == 'contract'
              ? DiagramKind.contract
              : DiagramKind.argument,
      description: json['description'] as String? ?? '',
      pattern:
          pattern is Map
              ? {
                for (final e in pattern.entries)
                  if (e.value is String && (e.value as String).isNotEmpty)
                    '${e.key}': e.value as String,
              }
              : {},
    );
  }

  /// 保存形式。何も設定していなければ null（JSON に書かない）。
  Map<String, Object>? toJson() {
    if (isEmpty) return null;
    final pat = {
      for (final e in pattern.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    return {
      if (kind == DiagramKind.contract) 'kind': 'contract',
      if (description.isNotEmpty) 'description': description,
      if (pat.isNotEmpty) 'pattern': pat,
    };
  }

  DiagramInfo copy() => DiagramInfo(
    kind: kind,
    description: description,
    pattern: Map.of(pattern),
  );
}

class DiagramSettingsDialog extends StatefulWidget {
  final DiagramInfo initial;

  /// 契約モジュールでは使えない要素・印の数（切り替えるときに注意を出す）
  final int contractViolations;

  const DiagramSettingsDialog({
    super.key,
    required this.initial,
    this.contractViolations = 0,
  });

  @override
  State<DiagramSettingsDialog> createState() => _DiagramSettingsDialogState();
}

class _DiagramSettingsDialogState extends State<DiagramSettingsDialog> {
  late DiagramKind _kind = widget.initial.kind;
  late final _descCtl = TextEditingController(text: widget.initial.description);
  late final Map<String, TextEditingController> _patternCtls = {
    for (final key in patternFields.keys)
      key: TextEditingController(text: widget.initial.pattern[key] ?? ''),
  };
  late bool _showPattern = widget.initial.pattern.values.any(
    (v) => v.isNotEmpty,
  );

  @override
  void dispose() {
    _descCtl.dispose();
    for (final c in _patternCtls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    Navigator.pop(
      context,
      DiagramInfo(
        kind: _kind,
        description: _descCtl.text.trim(),
        pattern: {
          for (final e in _patternCtls.entries)
            if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      scrollable: true,
      title: const Text('図の設定'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<DiagramKind>(
              segments: const [
                ButtonSegment(
                  value: DiagramKind.argument,
                  label: Text('論証モジュール'),
                ),
                ButtonSegment(
                  value: DiagramKind.contract,
                  label: Text('契約モジュール'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.single),
            ),
            const SizedBox(height: 6),
            Text(
              _kind == DiagramKind.contract
                  ? '契約モジュールは、あるモジュールの Goal を別のモジュールの Goal で'
                      'どう支えるかを Away 要素で書きます。Away Goal を支えてよく、'
                      '公開・Module Reference・Contract Reference・「契約で支える予定」は使えません。'
                  : '普通の論証です。',
              style: small,
            ),
            if (_kind == DiagramKind.contract && widget.contractViolations > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'この図には契約モジュールで使えない要素や印が '
                  '${widget.contractViolations} 個あります。'
                  '切り替えても消えませんが、図を直してください。',
                  style: small?.copyWith(color: Colors.red.shade700),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'モジュールの説明（任意）',
                helperText: 'モジュールインタフェースの一覧に載ります',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('パターン定義を書く'),
              subtitle: Text('GSN v3 1:3.4。パターン（テンプレート）の図に添える説明', style: small),
              value: _showPattern,
              onChanged: (v) => setState(() => _showPattern = v),
            ),
            if (_showPattern)
              for (final e in patternFields.entries)
                TextField(
                  controller: _patternCtls[e.key],
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(labelText: e.value),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
