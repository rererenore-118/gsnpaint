// アカウント（Firestore）への図の保存・読み出しに使うダイアログ。

import 'package:flutter/material.dart';

import 'cloud_diagram_service.dart';

/// 保存する図の名前を聞く。OK なら名前（前後の空白を除いたもの）を返す。
class CloudSaveDialog extends StatefulWidget {
  final String initialName;
  const CloudSaveDialog({super.key, required this.initialName});

  @override
  State<CloudSaveDialog> createState() => _CloudSaveDialogState();
}

class _CloudSaveDialogState extends State<CloudSaveDialog> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('アカウントに保存'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '図の名前',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            const Text('同じ名前の図がある場合は、確認のうえ上書きします。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル')),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}

/// 「アカウントから開く」で選ばれたもの（versionId があれば過去の版）
class CloudOpenResult {
  final CloudDiagram diagram;
  final CloudDiagramVersion? version;
  const CloudOpenResult(this.diagram, [this.version]);
}

String _formatTime(DateTime? t) {
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 自分の図の一覧から開く図を選ぶ。一覧から削除と、過去の版の表示もできる。
/// 選んだもの（CloudOpenResult）を返す（キャンセルなら null）。
class CloudOpenDialog extends StatefulWidget {
  final CloudDiagramService service;
  const CloudOpenDialog({super.key, required this.service});

  @override
  State<CloudOpenDialog> createState() => _CloudOpenDialogState();
}

class _CloudOpenDialogState extends State<CloudOpenDialog> {
  late Future<List<CloudDiagram>> _future = widget.service.list();

  void _reload() => setState(() => _future = widget.service.list());

  Future<void> _confirmDelete(CloudDiagram diagram) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('図の削除'),
        content: Text('「${diagram.name}」を過去の版も含めて削除します。元に戻せません。よろしいですか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.service.delete(diagram.id);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
      }
    }
  }

  Future<void> _showHistory(CloudDiagram diagram) async {
    final version = await showDialog<CloudDiagramVersion>(
      context: context,
      builder: (_) => _VersionHistoryDialog(service: widget.service, diagram: diagram),
    );
    if (version != null && mounted) Navigator.of(context).pop(CloudOpenResult(diagram, version));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('アカウントから開く'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: FutureBuilder<List<CloudDiagram>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('一覧の取得に失敗しました: ${snap.error}'));
            }
            final diagrams = snap.data!;
            if (diagrams.isEmpty) {
              return const Center(child: Text('保存済みの図はまだありません。'));
            }
            return ListView.separated(
              itemCount: diagrams.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final d = diagrams[i];
                return ListTile(
                  leading: Icon(d.unreadable ? Icons.warning_amber : Icons.description_outlined),
                  title: Text(d.name),
                  subtitle: Text(d.unreadable
                      ? '${_formatTime(d.updatedAt)}  復号できません（壊れているか書き換えられています）'
                      : _formatTime(d.updatedAt)),
                  // 復号できないデータは開けない（削除だけできる）
                  onTap: d.unreadable
                      ? null
                      : () => Navigator.of(context).pop(CloudOpenResult(d)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (!d.unreadable)
                      IconButton(
                        icon: const Icon(Icons.history),
                        tooltip: '過去の版',
                        onPressed: () => _showHistory(d),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '削除',
                      onPressed: () => _confirmDelete(d),
                    ),
                  ]),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる')),
      ],
    );
  }
}

/// 図の過去の版の一覧。開く版を選ぶ（キャンセルなら null）。
class _VersionHistoryDialog extends StatelessWidget {
  final CloudDiagramService service;
  final CloudDiagram diagram;
  const _VersionHistoryDialog({required this.service, required this.diagram});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('「${diagram.name}」の過去の版'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: FutureBuilder<List<CloudDiagramVersion>>(
          future: service.listVersions(diagram.id),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('一覧の取得に失敗しました: ${snap.error}'));
            }
            final versions = snap.data!;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                '上書き保存するたびに、それまでの内容が残ります（新しい順に'
                '${CloudDiagramService.maxVersions}件まで）。開いた版は、保存すると最新の版になります。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: versions.isEmpty
                    ? const Center(child: Text('過去の版はまだありません。'))
                    : ListView.separated(
                        itemCount: versions.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) => ListTile(
                          leading: const Icon(Icons.restore),
                          title: Text(_formatTime(versions[i].savedAt)),
                          subtitle: Text(i == 0 ? '最新の1つ前' : '${i + 1}つ前'),
                          onTap: () => Navigator.of(context).pop(versions[i]),
                        ),
                      ),
              ),
            ]);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('閉じる')),
      ],
    );
  }
}
