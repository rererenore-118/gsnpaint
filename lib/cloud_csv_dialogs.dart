// アカウント（Firestore）に保存したCSVの管理画面（一覧・中身の確認・削除）。
// CSVは暗号化して保存しているので、一覧を出すときにブラウザ内で復号する（呼び出し側で先に解除しておく）。

import 'package:flutter/material.dart';

import 'cloud_csv_service.dart';

String _formatTime(DateTime? t) {
  if (t == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String _formatSize(int bytes) =>
    bytes < 1000 ? '$bytes B' : '${(bytes / 1000).toStringAsFixed(1)} KB';

class CsvManagerDialog extends StatefulWidget {
  final CloudCsvService service;

  /// 編集中の図の FileList ノードが使っているCSVの名前（削除するときに注意を出す）
  final Set<String> usedNames;

  const CsvManagerDialog({super.key, required this.service, required this.usedNames});

  @override
  State<CsvManagerDialog> createState() => _CsvManagerDialogState();
}

class _CsvManagerDialogState extends State<CsvManagerDialog> {
  late Future<List<CloudCsvFile>> _future = widget.service.list();

  void _reload() => setState(() => _future = widget.service.list());

  Future<void> _preview(CloudCsvFile file) async {
    const maxLines = 20;
    // 最後の改行のあとの空行は行数に入れない
    final lines = file.content.replaceFirst(RegExp(r'(\r?\n)+$'), '').split(RegExp(r'\r?\n'));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(file.name),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${lines.length}行・${_formatSize(file.sizeBytes)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 360),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: SelectableText(
                    lines.take(maxLines).join('\n') +
                        (lines.length > maxLines ? '\n…（先頭$maxLines行だけ表示）' : ''),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('閉じる')),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(CloudCsvFile file) async {
    final used = widget.usedNames.contains(file.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('CSVの削除'),
        content: Text('「${file.name}」を削除します。元に戻せません。よろしいですか？'
            '${used ? '\n\n編集中の図がこのCSVを使っています。削除すると、この図は評価できなくなります。' : ''}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.service.delete(file.id);
      _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('削除に失敗しました: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('アカウントのCSV'),
      content: SizedBox(
        width: 460,
        height: 380,
        child: FutureBuilder<List<CloudCsvFile>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('一覧の取得に失敗しました: ${snap.error}'));
            }
            final files = snap.data!;
            if (files.isEmpty) {
              return const Center(child: Text('アカウントにCSVはまだありません。'));
            }
            return ListView.separated(
              itemCount: files.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final f = files[i];
                final used = widget.usedNames.contains(f.name);
                return ListTile(
                  leading: const Icon(Icons.table_chart_outlined),
                  title: Text(f.name),
                  subtitle: Text([
                    _formatSize(f.sizeBytes),
                    _formatTime(f.updatedAt),
                    if (used) '編集中の図で使用中',
                  ].where((s) => s.isNotEmpty).join('・')),
                  onTap: () => _preview(f),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '削除',
                    onPressed: () => _confirmDelete(f),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('閉じる')),
      ],
    );
  }
}
