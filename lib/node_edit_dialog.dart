// ノードの編集ダイアログ。普通の要素と、別の図を参照する Away 要素を 1 つのダイアログで扱う。
// main.dart は dart:html と Firebase に依存するので、ダイアログだけをここに分けて
// 単体でテストできるようにしている（test/node_edit_dialog_test.dart）。
import 'package:flutter/material.dart';

/// ダイアログで「保存」を押したときの内容。
class NodeEditResult {
  final String label;
  final bool isAway;
  final String module;
  final bool isPublic;
  final bool isUndeveloped;

  const NodeEditResult({
    required this.label,
    required this.isAway,
    required this.module,
    required this.isPublic,
    required this.isUndeveloped,
  });
}

class NodeEditDialog extends StatefulWidget {
  /// 要素の種類の表示名（Goal、Evidence など）。Away かどうかには関係しない。
  final String typeName;
  final String initialLabel;
  final String initialModule;
  final bool initialIsAway;
  final bool initialIsPublic;
  final bool initialIsUndeveloped;

  /// 「別の図を参照する」を出すか。参照先になれる種類の要素だけ true。
  final bool canReference;
  final bool canBePublic;
  final bool canBeUndeveloped;

  /// 普通の要素から Away にできない理由。null なら切り替えられる。
  final String? referenceBlockedReason;
  final String? undevelopedHint;

  /// アカウントに保存した図から参照先を選ぶ。
  final Future<String?> Function()? pickModule;

  /// 参照先の図の公開要素から説明文を選ぶ。引数は参照先のモジュール名。
  final Future<String?> Function(String module)? pickClaim;

  const NodeEditDialog({
    super.key,
    required this.typeName,
    required this.initialLabel,
    this.initialModule = '',
    this.initialIsAway = false,
    this.initialIsPublic = false,
    this.initialIsUndeveloped = false,
    this.canReference = false,
    this.canBePublic = false,
    this.canBeUndeveloped = false,
    this.referenceBlockedReason,
    this.undevelopedHint,
    this.pickModule,
    this.pickClaim,
  });

  @override
  State<NodeEditDialog> createState() => _NodeEditDialogState();
}

class _NodeEditDialogState extends State<NodeEditDialog> {
  late final TextEditingController _labelCtl =
      TextEditingController(text: widget.initialLabel);
  late final TextEditingController _moduleCtl =
      TextEditingController(text: widget.initialModule);
  late bool _isAway = widget.initialIsAway;
  late bool _isPublic = widget.initialIsPublic;
  late bool _isUndeveloped = widget.initialIsUndeveloped;

  @override
  void dispose() {
    _labelCtl.dispose();
    _moduleCtl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_labelCtl.text.isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      NodeEditResult(
        label: _labelCtl.text,
        isAway: _isAway,
        module: _isAway ? _moduleCtl.text.trim() : '',
        isPublic: !_isAway && widget.canBePublic && _isPublic,
        isUndeveloped: !_isAway && widget.canBeUndeveloped && _isUndeveloped,
      ),
    );
  }

  Future<void> _pickClaim() async {
    final claim = await widget.pickClaim?.call(_moduleCtl.text.trim());
    if (claim != null) _labelCtl.text = claim;
  }

  Future<void> _pickModule() async {
    final name = await widget.pickModule?.call();
    if (name != null) _moduleCtl.text = name;
  }

  String get _labelText => widget.typeName == 'Goal'
      ? '主張（参照先のゴールと同じ文面）'
      : '説明（参照先の ${widget.typeName} と同じ文面）';

  @override
  Widget build(BuildContext context) {
    // 普通の要素から Away への切り替えだけを止める。すでに Away なら外せる。
    final blockedReason = _isAway ? null : widget.referenceBlockedReason;
    final chips = <Widget>[
      if (widget.canReference)
        FilterChip(
          label: const Text('別の図を参照'),
          tooltip: 'この要素の内容は別の図にある（Away ${widget.typeName}）',
          selected: _isAway,
          onSelected: blockedReason != null
              ? null
              : (v) => setState(() => _isAway = v),
        ),
      if (!_isAway && widget.canBePublic)
        FilterChip(
          label: const Text('公開'),
          tooltip: '他の図の Away 要素から参照できるようにする',
          selected: _isPublic,
          onSelected: (v) => setState(() => _isPublic = v),
        ),
      if (!_isAway && widget.canBeUndeveloped)
        FilterChip(
          label: const Text('未展開'),
          tooltip: widget.undevelopedHint ?? 'この先の論証はまだ書いていない',
          selected: _isUndeveloped,
          onSelected: (v) => setState(() => _isUndeveloped = v),
        ),
    ];
    return AlertDialog(
      // 窓が低いときは中身をスクロールさせる（下にはみ出すのを防ぐ）
      scrollable: true,
      title: Text(_isAway ? 'Away ${widget.typeName} の編集' : 'ノード名編集'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _labelCtl,
            autofocus: true,
            decoration: _isAway
                ? InputDecoration(
                    labelText: _labelText,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.list),
                      tooltip: '参照先の公開 ${widget.typeName} から選ぶ',
                      onPressed: _pickClaim,
                    ),
                  )
                : const InputDecoration(),
            onSubmitted: (_) => _submit(),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 8, runSpacing: 4, children: chips),
            ),
          ],
          if (blockedReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  blockedReason,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          if (_isAway)
            TextField(
              controller: _moduleCtl,
              decoration: InputDecoration(
                labelText: '参照先のモジュール名',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.folder_special),
                  tooltip: 'アカウントに保存した図から選ぶ',
                  onPressed: _pickModule,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
        ],
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
