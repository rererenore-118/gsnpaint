// 線（関係）の設定ダイアログ。GSN v3 の構造の抽象化（1:3.2）のうち、線に付ける
// Multiplicity（黒丸・個数）と Optionality（白丸）を選び、線の削除もここから行う。
// main.dart は dart:html と Firebase に依存するので、単体でテストできるよう分けている
// （test/edge_edit_dialog_test.dart）。
import 'package:flutter/material.dart';

/// 線に付ける GSN v3 の印。
enum EdgeMultiplicity {
  /// 印なし（普通の 1 対 1 の関係）
  none,

  /// 黒丸: 複数の実体化（個数の注記を付けられる。無ければ 1 以上）
  many,

  /// 白丸: 任意（実体化してもしなくてもよい）
  optional,
}

const _multiplicityNames = {
  EdgeMultiplicity.many: 'many',
  EdgeMultiplicity.optional: 'optional',
};

/// 保存形式の文字列から読む。知らない値は印なしとして扱う。
EdgeMultiplicity edgeMultiplicityFromJson(Object? value) {
  for (final e in _multiplicityNames.entries) {
    if (e.value == value) return e.key;
  }
  return EdgeMultiplicity.none;
}

/// 保存形式の文字列。印なしは null（JSON に書かない）。
String? edgeMultiplicityToJson(EdgeMultiplicity m) => _multiplicityNames[m];

/// アーキテクチャ図（GSN v3 1:4.4）でモジュールどうしをつなぐ線の端の形。
enum ModuleLinkEnd {
  /// 矢じりなし
  none,

  /// 黒塗りの矢じり（ModuleSupportedBy）
  supported,

  /// 白抜きの矢じり（ModuleInContextOf）
  context,

  /// 二重の開いた矢じり（支えと文脈の両方: Composite）
  composite,
}

ModuleLinkEnd moduleLinkEndFromJson(Object? value, ModuleLinkEnd fallback) {
  for (final e in ModuleLinkEnd.values) {
    if (e.name == value) return e;
  }
  return fallback;
}

const moduleLinkEndNames = {
  ModuleLinkEnd.none: 'なし',
  ModuleLinkEnd.supported: '支える（▶）',
  ModuleLinkEnd.context: '文脈（▷）',
  ModuleLinkEnd.composite: '両方（≫）',
};

/// PGSN の Record を扱う線。以前は RecordLabel / RecordAccess という要素を線の途中に
/// 置いていたが、親 1・子 1 のつなぎ方に名前を付けるだけなので、線の種類にした。
/// 評価に送るときは要素に戻す（build_gsn.py は変えない）。
enum RecordLink {
  /// 普通の線
  none,

  /// Record → 値: その値をキー名で Record に入れる（一本線）
  label,

  /// 親 → Record: Record からキー名の値を取り出す（二重線）
  access,
}

RecordLink recordLinkFromJson(Object? value) {
  for (final e in RecordLink.values) {
    if (e != RecordLink.none && e.name == value) return e;
  }
  return RecordLink.none;
}

/// 線の設定ダイアログで Record のキーをどう扱うか
enum RecordEditMode {
  /// Record の線ではない
  none,

  /// Record から値への線: 必ずキー名を付ける
  label,

  /// 子が Record（の値）になる線: 値を取り出す線にできる
  accessAllowed,
}

/// 線の設定ダイアログで扱える線の種類
enum EdgeEditKind {
  /// GSN の要素どうしの線: Multiplicity / Optionality と ACP
  gsn,

  /// アーキテクチャ図のモジュールどうしの線: 両端の矢じりとインタフェース
  architecture,

  /// それ以外（λ計算など）: 削除だけ
  other,
}

/// ダイアログの結果。[delete] が true なら線を消す。
class EdgeEditResult {
  final EdgeMultiplicity multiplicity;
  final String cardinality;
  final String acp;
  final ModuleLinkEnd archHead;
  final ModuleLinkEnd archTail;
  final String fromInterface;
  final String toInterface;
  final RecordLink recordLink;
  final String recordKey;
  final bool delete;

  const EdgeEditResult({
    this.multiplicity = EdgeMultiplicity.none,
    this.cardinality = '',
    this.acp = '',
    this.archHead = ModuleLinkEnd.supported,
    this.archTail = ModuleLinkEnd.none,
    this.fromInterface = '',
    this.toInterface = '',
    this.recordLink = RecordLink.none,
    this.recordKey = '',
    this.delete = false,
  });
}

class EdgeEditDialog extends StatefulWidget {
  /// 「Goal → Strategy」のような、どの線かの説明
  final String title;
  final EdgeEditKind kind;
  final EdgeMultiplicity initialMultiplicity;
  final String initialCardinality;
  final String initialAcp;
  final ModuleLinkEnd initialArchHead;
  final ModuleLinkEnd initialArchTail;
  final String initialFromInterface;
  final String initialToInterface;
  final RecordEditMode recordMode;
  final RecordLink initialRecordLink;
  final String initialRecordKey;

  /// 始点・終点のモジュール名（アーキテクチャ図の線で、インタフェース欄の見出しに使う）
  final String fromName;
  final String toName;

  const EdgeEditDialog({
    super.key,
    required this.title,
    this.kind = EdgeEditKind.gsn,
    this.initialMultiplicity = EdgeMultiplicity.none,
    this.initialCardinality = '',
    this.initialAcp = '',
    this.initialArchHead = ModuleLinkEnd.supported,
    this.initialArchTail = ModuleLinkEnd.none,
    this.initialFromInterface = '',
    this.initialToInterface = '',
    this.recordMode = RecordEditMode.none,
    this.initialRecordLink = RecordLink.none,
    this.initialRecordKey = '',
    this.fromName = '始点',
    this.toName = '終点',
  });

  @override
  State<EdgeEditDialog> createState() => _EdgeEditDialogState();
}

class _EdgeEditDialogState extends State<EdgeEditDialog> {
  late EdgeMultiplicity _multiplicity = widget.initialMultiplicity;
  late final _cardinalityCtl = TextEditingController(
    text: widget.initialCardinality,
  );
  late final _acpCtl = TextEditingController(text: widget.initialAcp);
  late ModuleLinkEnd _head = widget.initialArchHead;
  late ModuleLinkEnd _tail = widget.initialArchTail;
  late final _fromIfCtl = TextEditingController(
    text: widget.initialFromInterface,
  );
  late final _toIfCtl = TextEditingController(text: widget.initialToInterface);
  late bool _access = widget.initialRecordLink == RecordLink.access;
  late final _keyCtl = TextEditingController(text: widget.initialRecordKey);

  @override
  void dispose() {
    _cardinalityCtl.dispose();
    _acpCtl.dispose();
    _fromIfCtl.dispose();
    _toIfCtl.dispose();
    _keyCtl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(
      context,
      EdgeEditResult(
        multiplicity: _multiplicity,
        // 個数の注記は黒丸にだけ付く
        cardinality:
            _multiplicity == EdgeMultiplicity.many
                ? _cardinalityCtl.text.trim()
                : '',
        acp: _acpCtl.text.trim(),
        archHead: _head,
        archTail: _tail,
        fromInterface: _fromIfCtl.text.trim(),
        toInterface: _toIfCtl.text.trim(),
        recordLink: _recordLink,
        recordKey: _recordLink == RecordLink.none ? '' : _keyCtl.text.trim(),
      ),
    );
  }

  RecordLink get _recordLink => switch (widget.recordMode) {
    RecordEditMode.label => RecordLink.label,
    RecordEditMode.accessAllowed => _access ? RecordLink.access : RecordLink.none,
    RecordEditMode.none => RecordLink.none,
  };

  Widget _keyField({required String hint}) => TextField(
    controller: _keyCtl,
    autofocus: true,
    decoration: InputDecoration(labelText: 'キー名', hintText: hint),
    onSubmitted: (_) => _submit(),
  );

  Widget _recordContent(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    if (widget.recordMode == RecordEditMode.label) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _keyField(hint: '例: name、version'),
          const SizedBox(height: 8),
          Text('先の値を、このキー名で Record に入れます（一本線）。', style: small),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Record から値を取り出す'),
          subtitle: Text('先の Record から、キー名の値を取り出して使います（二重線）', style: small),
          value: _access,
          onChanged: (v) => setState(() => _access = v),
        ),
        if (_access) _keyField(hint: '例: name'),
      ],
    );
  }

  Widget _option(EdgeMultiplicity value, String label, String hint) =>
      RadioListTile<EdgeMultiplicity>(
        value: value,
        title: Text(label),
        subtitle: Text(hint),
        dense: true,
        contentPadding: EdgeInsets.zero,
      );

  Widget _gsnContent(BuildContext context) => RadioGroup<EdgeMultiplicity>(
    groupValue: _multiplicity,
    onChanged: (v) => setState(() => _multiplicity = v!),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _option(EdgeMultiplicity.none, '印なし', '1 対 1 の関係'),
        _option(EdgeMultiplicity.many, '複数（●）', '先の要素が複数ある。個数を書かなければ 1 以上'),
        if (_multiplicity == EdgeMultiplicity.many)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: TextField(
              controller: _cardinalityCtl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '個数（任意）',
                hintText: '例: n、0..x、2',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
        _option(EdgeMultiplicity.optional, '任意（○）', 'この線と先の論証はあってもなくてもよい'),
        const SizedBox(height: 8),
        TextField(
          controller: _acpCtl,
          decoration: const InputDecoration(
            labelText: 'ACP（任意）',
            hintText: '例: ACP1、ACP1[Confidence]',
            helperText: 'この関係への確信を別の論証で示すときの識別子（■）',
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 8),
        Text(
          'GSN のパターン・確信の論証の記法です。評価には影響しません。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  Widget _endPicker(
    String label,
    ModuleLinkEnd value,
    ValueChanged<ModuleLinkEnd> onChanged,
  ) => Row(
    children: [
      Expanded(child: Text(label)),
      DropdownButton<ModuleLinkEnd>(
        value: value,
        items: [
          for (final e in ModuleLinkEnd.values)
            DropdownMenuItem(value: e, child: Text(moduleLinkEndNames[e]!)),
        ],
        onChanged: (v) => setState(() => onChanged(v!)),
      ),
    ],
  );

  Widget _architectureContent(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _endPicker('${widget.toName} 側の矢じり', _head, (v) => _head = v),
      _endPicker('${widget.fromName} 側の矢じり', _tail, (v) => _tail = v),
      TextField(
        controller: _fromIfCtl,
        decoration: InputDecoration(
          labelText: '${widget.fromName} のインタフェース（任意）',
          hintText: '例: interface_1',
        ),
        onSubmitted: (_) => _submit(),
      ),
      TextField(
        controller: _toIfCtl,
        decoration: InputDecoration(
          labelText: '${widget.toName} のインタフェース（任意）',
          hintText: '例: interface_1',
        ),
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 8),
      Text(
        '支える: ModuleSupportedBy、文脈: ModuleInContextOf、両方: Composite。'
        'インタフェースを書くと、モジュールの縁に小さな四角を描きます。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final canEdit =
        widget.kind != EdgeEditKind.other ||
        widget.recordMode != RecordEditMode.none;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: switch (widget.kind) {
          EdgeEditKind.gsn => _gsnContent(context),
          EdgeEditKind.architecture => _architectureContent(context),
          EdgeEditKind.other =>
            widget.recordMode == RecordEditMode.none
                ? const Text('この線には印を付けられません。')
                : _recordContent(context),
        },
      ),
      actions: [
        TextButton(
          onPressed:
              () => Navigator.pop(context, const EdgeEditResult(delete: true)),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('線を削除'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        if (canEdit) TextButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
