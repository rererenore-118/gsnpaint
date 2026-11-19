// 評価実験のアンケートに答えるダイアログ。中身は lib/survey.dart。
// main.dart は dart:html と Firebase に依存するので、単体でテストできるよう分けている
// （test/survey_dialog_test.dart）。送信すると [SurveyResponse] を返す。
import 'package:flutter/material.dart';

import 'survey.dart';

class SurveyDialog extends StatefulWidget {
  const SurveyDialog({super.key});

  @override
  State<SurveyDialog> createState() => _SurveyDialogState();
}

class _SurveyDialogState extends State<SurveyDialog> {
  final _answers = <String, Object>{};
  late final Map<String, TextEditingController> _textCtls = {
    for (final k in freeTextQuestions.keys) k: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _textCtls.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _missing => SurveyResponse.missingCount(_answers);

  Future<void> _submit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('送信の確認'),
            content: const Text('送信すると、あとから回答を変えられません。送信しますか？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('見直す'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('送信'),
              ),
            ],
          ),
    );
    if (ok != true || !mounted) return;
    Navigator.pop(
      context,
      SurveyResponse(
        answers: {
          ..._answers,
          for (final e in _textCtls.entries) e.key: e.value.text.trim(),
        },
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _choiceQuestion(String key, String title, Map<String, String> options) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final o in options.entries)
                  ChoiceChip(
                    label: Text(o.value),
                    selected: _answers[key] == o.key,
                    onSelected: (_) => setState(() => _answers[key] = o.key),
                  ),
              ],
            ),
          ],
        ),
      );

  Widget _likert(int i) {
    final key = susKey(i);
    final value = _answers[key];
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${i + 1}. ${susItems[i]}'),
          const SizedBox(height: 4),
          SegmentedButton<int>(
            showSelectedIcon: false,
            emptySelectionAllowed: true,
            segments: [
              for (var v = 1; v <= 5; v++)
                ButtonSegment(
                  value: v,
                  label: Text('$v'),
                  tooltip: likertLabels[v - 1],
                ),
            ],
            selected: {if (value is int) value},
            onSelectionChanged: (s) {
              if (s.isEmpty) return;
              setState(() => _answers[key] = s.single);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final missing = _missing;
    return AlertDialog(
      scrollable: true,
      title: const Text('アンケート'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'エディタを使ってみた感想を教えてください。回答は研究のためにだけ使い、'
              'メールアドレスは保存しません。送信は 1 回だけです。',
              style: small,
            ),
            _heading('あなたについて'),
            for (final e in backgroundQuestions.entries)
              _choiceQuestion(e.key, e.value.$1, e.value.$2),
            _heading('エディタの使いやすさ'),
            Text(
              '1: ${likertLabels.first} 〜 5: ${likertLabels.last}',
              style: small,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < susItems.length; i++) _likert(i),
            _heading('自由記述（任意）'),
            for (final e in freeTextQuestions.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _textCtls[e.key],
                  minLines: 2,
                  maxLines: 5,
                  maxLength: maxFreeTextLength,
                  decoration: InputDecoration(
                    labelText: e.value,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (missing > 0)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text('未回答 $missing 問', style: small),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: missing == 0 ? _submit : null,
          child: const Text('送信'),
        ),
      ],
    );
  }
}
