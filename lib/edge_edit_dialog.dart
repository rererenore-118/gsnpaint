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

/// ダイアログの結果。[delete] が true なら線を消す。
class EdgeEditResult {
  final EdgeMultiplicity multiplicity;
  final String cardinality;
  final bool delete;

  const EdgeEditResult({
    this.multiplicity = EdgeMultiplicity.none,
    this.cardinality = '',
    this.delete = false,
  });
}

class EdgeEditDialog extends StatefulWidget {
  /// 「Goal → Strategy」のような、どの線かの説明
  final String title;
  final EdgeMultiplicity initialMultiplicity;
  final String initialCardinality;

  /// 印を付けられる線か（GSN の要素どうしの線だけ）。false なら削除だけ出す。
  final bool canDecorate;

  const EdgeEditDialog({
    super.key,
    required this.title,
    this.initialMultiplicity = EdgeMultiplicity.none,
    this.initialCardinality = '',
    this.canDecorate = true,
  });

  @override
  State<EdgeEditDialog> createState() => _EdgeEditDialogState();
}

class _EdgeEditDialogState extends State<EdgeEditDialog> {
  late EdgeMultiplicity _multiplicity = widget.initialMultiplicity;
  late final TextEditingController _cardinalityCtl = TextEditingController(
    text: widget.initialCardinality,
  );

  @override
  void dispose() {
    _cardinalityCtl.dispose();
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
      ),
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child:
            widget.canDecorate
                ? RadioGroup<EdgeMultiplicity>(
                  groupValue: _multiplicity,
                  onChanged: (v) => setState(() => _multiplicity = v!),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _option(EdgeMultiplicity.none, '印なし', '1 対 1 の関係'),
                      _option(
                        EdgeMultiplicity.many,
                        '複数（●）',
                        '先の要素が複数ある。個数を書かなければ 1 以上',
                      ),
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
                      _option(
                        EdgeMultiplicity.optional,
                        '任意（○）',
                        'この線と先の論証はあってもなくてもよい',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'GSN のパターン用の記法です。評価には影響しません。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
                : const Text('この線には印を付けられません。'),
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
        if (widget.canDecorate)
          TextButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
