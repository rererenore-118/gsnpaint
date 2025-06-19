import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('GSN描画サンプル')),
        body: CustomPaint(
          painter: GsnPainter(),
          child: Container(),
        ),
      ),
    );
  }
}

class GsnPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint rectPaint = Paint()
      ..color = Colors.lightBlue.shade100
      ..style = PaintingStyle.fill;

    final Paint borderPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // ノードの座標・サイズ
    const double nodeWidth = 120;
    const double nodeHeight = 60;

    final Offset goalPos = const Offset(150, 50);
    final Offset strategyPos = const Offset(150, 150);
    final Offset solutionPos = const Offset(150, 250);

    // Goalノード描画
    final Rect goalRect = Rect.fromLTWH(goalPos.dx, goalPos.dy, nodeWidth, nodeHeight);
    canvas.drawRect(goalRect, rectPaint);
    canvas.drawRect(goalRect, borderPaint);
    _drawText(canvas, 'Goal', goalPos, nodeWidth);

    // Strategyノード描画
    final Rect strategyRect = Rect.fromLTWH(strategyPos.dx, strategyPos.dy, nodeWidth, nodeHeight);
    canvas.drawRect(strategyRect, rectPaint);
    canvas.drawRect(strategyRect, borderPaint);
    _drawText(canvas, 'Strategy', strategyPos, nodeWidth);

    // Solutionノード描画
    final Rect solutionRect = Rect.fromLTWH(solutionPos.dx, solutionPos.dy, nodeWidth, nodeHeight);
    canvas.drawRect(solutionRect, rectPaint);
    canvas.drawRect(solutionRect, borderPaint);
    _drawText(canvas, 'Solution', solutionPos, nodeWidth);

    // 矢印線（簡略）
    final arrowPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2;
    canvas.drawLine(goalPos.translate(nodeWidth / 2, nodeHeight), strategyPos.translate(nodeWidth / 2, 0), arrowPaint);
    canvas.drawLine(strategyPos.translate(nodeWidth / 2, nodeHeight), solutionPos.translate(nodeWidth / 2, 0), arrowPaint);
  }

  void _drawText(Canvas canvas, String text, Offset offset, double width) {
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(color: Colors.black, fontSize: 14),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout(minWidth: width, maxWidth: width);
    textPainter.paint(canvas, offset.translate(0, 20));
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
