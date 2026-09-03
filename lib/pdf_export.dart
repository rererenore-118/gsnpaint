// GSN図をPDFとして書き出す処理。
// 編集中の図（評価前）と評価結果ビューアの図（評価後）の両方から使う。
//
// 仕組み: ウィジェットツリーを介さず、画面と同じCustomPainterをオフスクリーンの
// Canvasへ直接描き、できたPNGを1ページのPDFに貼り付けてブラウザにダウンロードさせる。
// RepaintBoundary.toImage() を使わないのは、キャンバスの論理サイズが4000x4000と大きく
// 画面外も含めて丸ごとラスタライズすると重すぎるため。ここではノードの外接矩形だけを
// 切り出して描画するので、図の大きさに応じた最小限のサイズで済む。
part of 'main.dart';

// 図の周囲に付ける余白（論理px）。エッジの折れ点が外接矩形をわずかに越えても切れないようにする。
const double _pdfMargin = 40.0;
// 出力するラスタ画像の最大辺（px）。大きな図でメモリを食い潰さないための上限。
const double _pdfMaxPixels = 6000.0;
// ラスタ化の基本倍率。PDFを拡大表示しても文字がぼやけない程度に高めに取る。
const double _pdfScale = 3.0;

// ラスタ化した図。widthとheightは論理サイズ（=PDFのページサイズ, pt）。
class _DiagramRaster {
  final Uint8List bytes;
  final double width;
  final double height;
  const _DiagramRaster(this.bytes, this.width, this.height);
}

/// ノードとエッジをオフスクリーンに描画し、PNGバイト列として返す。
/// [edgePainter] は呼び出し元（エディタ/ビューア）が画面で使っているものをそのまま渡す。
/// 画面と同じPainterを使うことで「見えている図」と出力が一致する。
Future<_DiagramRaster> _renderDiagramPng({
  required List<GsnNode> nodes,
  required List<GsnEdge> edges,
  required CustomPainter edgePainter,
}) async {
  if (nodes.isEmpty) {
    throw StateError('出力できるノードがありません');
  }

  // ノードの外接矩形を求める
  double minX = double.infinity;
  double minY = double.infinity;
  double maxX = -double.infinity;
  double maxY = -double.infinity;
  for (final n in nodes) {
    minX = min(minX, n.position.dx);
    minY = min(minY, n.position.dy);
    maxX = max(maxX, n.position.dx + n.width);
    maxY = max(maxY, n.position.dy + n.height);
  }

  final logicalWidth = (maxX - minX) + _pdfMargin * 2;
  final logicalHeight = (maxY - minY) + _pdfMargin * 2;

  // 上限を超えないよう倍率を調整する
  double scale = _pdfScale;
  final longestSide = max(logicalWidth, logicalHeight);
  if (longestSide * scale > _pdfMaxPixels) {
    scale = max(1.0, _pdfMaxPixels / longestSide);
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(scale);

  // PDFの背景は透過だと見づらいので白で塗る
  canvas.drawRect(
    Rect.fromLTWH(0, 0, logicalWidth, logicalHeight),
    Paint()..color = Colors.white,
  );

  // 以降はワールド座標（ノードのposition）そのままで描けるように原点をずらす
  canvas.translate(_pdfMargin - minX, _pdfMargin - minY);

  edgePainter.paint(canvas, Size(maxX, maxY));

  for (final node in nodes) {
    canvas.save();
    canvas.translate(node.position.dx, node.position.dy);
    _paintNodeToCanvas(
      canvas,
      node,
      defeaterBacked: node.type == GsnNodeType.defeater
          ? _isDefeaterBacked(node, nodes, edges)
          : false,
    );
    canvas.restore();
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (logicalWidth * scale).ceil(),
    (logicalHeight * scale).ceil(),
  );
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  if (byteData == null) {
    throw StateError('画像の生成に失敗しました');
  }
  return _DiagramRaster(
      byteData.buffer.asUint8List(), logicalWidth, logicalHeight);
}

/// 1つのノードを（原点をノード左上に移動済みの）canvasへ描く。
/// 描き分けは _buildGsnShapeWidget() と対になっているので、
/// ノードの見た目を変更したときは両方を揃えること。
void _paintNodeToCanvas(Canvas canvas, GsnNode node,
    {required bool defeaterBacked}) {
  final size = Size(node.width, node.height);
  CustomPainter? painter;
  var drawLabel = true;

  switch (node.type) {
    case GsnNodeType.goal:
      // Container(色 + Border.all()) 相当。枠線はウィジェットと同じく内側に描く。
      final rect = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawRect(rect, Paint()..color = Colors.lightBlue.shade100);
      canvas.drawRect(
        rect.deflate(0.5),
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      break;
    case GsnNodeType.strategy:
      painter = ParallelogramPainter(Colors.orangeAccent.shade100);
      break;
    case GsnNodeType.evidence:
      painter = EvidencePainter();
      break;
    case GsnNodeType.undeveloped:
      painter = UndevelopedPainter();
      break;
    case GsnNodeType.record:
      painter = RecordPainter();
      break;
    case GsnNodeType.lambda:
      // Painterがラベルまで描くタイプ
      painter = LambdaPainter(label: node.label);
      drawLabel = false;
      break;
    case GsnNodeType.application:
      // キャンバス上ではラベルを出さない（図形だけで型が分かるため）
      painter = ApplicationPainter();
      drawLabel = false;
      break;
    case GsnNodeType.map:
      painter = MapPainter();
      drawLabel = false;
      break;
    case GsnNodeType.stringLiteral:
      painter = StringLiteralPainter();
      break;
    case GsnNodeType.recordLabel:
      painter = RecordLabelPainter(label: node.label);
      drawLabel = false;
      break;
    case GsnNodeType.recordAccess:
      painter = RecordAccessPainter(label: node.label);
      drawLabel = false;
      break;
    case GsnNodeType.context:
      painter = RoundedRectPainter(Colors.purple.shade100, 12);
      break;
    case GsnNodeType.assumption:
      painter = AnnotatedOvalPainter(Colors.yellow.shade100, 'A');
      break;
    case GsnNodeType.justification:
      painter = AnnotatedOvalPainter(Colors.teal.shade100, 'J');
      break;
    case GsnNodeType.defeater:
      painter = DefeaterPainter(backed: defeaterBacked);
      break;
    case GsnNodeType.x:
      painter = XPainter();
      break;
    case GsnNodeType.fileList:
      _paintFileListNode(canvas, node, size);
      drawLabel = false;
      break;
  }

  painter?.paint(canvas, size);
  if (drawLabel) {
    _paintNodeLabel(canvas, node, size);
  }
}

/// ノード中央のラベル。ウィジェット側の Center + Padding(8) + Text 相当。
void _paintNodeLabel(Canvas canvas, GsnNode node, Size size) {
  if (node.label.isEmpty) return;
  final tp = TextPainter(
    text: TextSpan(
      text: node.label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: node.type == GsnNodeType.map ? Colors.white : Colors.black,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: max(0.0, size.width - 16));
  tp.paint(
    canvas,
    Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
  );
}

/// CSVファイル参照ノード。角丸の緑枠 + アイコン + ラベル。
void _paintFileListNode(Canvas canvas, GsnNode node, Size size) {
  final rrect = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, size.width, size.height).deflate(1),
    const Radius.circular(6),
  );
  canvas.drawRRect(rrect, Paint()..color = Colors.green.shade100);
  canvas.drawRRect(
    rrect,
    Paint()
      ..color = Colors.green.shade700
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );

  final icon = Icons.table_chart;
  final tp = TextPainter(
    text: TextSpan(children: [
      TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 16,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.green.shade800,
        ),
      ),
      const TextSpan(text: ' '),
      TextSpan(
        text: node.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.green.shade900,
        ),
      ),
    ]),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: max(0.0, size.width - 12));
  tp.paint(
    canvas,
    Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
  );
}

/// 図をPDF化してブラウザにダウンロードさせる。
/// ページサイズは図の実寸（1論理px = 1pt）に合わせるので、図が切れることはない。
Future<void> _exportDiagramPdf({
  required List<GsnNode> nodes,
  required List<GsnEdge> edges,
  required CustomPainter edgePainter,
  required String fileName,
}) async {
  final raster = await _renderDiagramPng(
    nodes: nodes,
    edges: edges,
    edgePainter: edgePainter,
  );

  final doc = pw.Document();
  final image = pw.MemoryImage(raster.bytes);
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(raster.width, raster.height, marginAll: 0),
      build: (context) => pw.Image(
        image,
        width: raster.width,
        height: raster.height,
        fit: pw.BoxFit.fill,
      ),
    ),
  );

  final bytes = await doc.save();
  final blob = html.Blob([bytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..setAttribute('download', fileName)
    ..click();
  html.Url.revokeObjectUrl(url);
}

/// PDF出力の失敗をダイアログで知らせる。
/// 評価結果ビューアはダイアログの上に表示されているためSnackBarだと隠れてしまう。
void _showPdfErrorDialog(BuildContext context, Object error) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('PDF出力エラー'),
      content: Text('$error'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
