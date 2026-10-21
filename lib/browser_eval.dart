// ブラウザ内評価（Pyodide）を呼ぶ。
// 実体は web/pgsn/pgsn_eval.js（window.pgsnEval）で、評価用の Python のコード
// （gsn_eval.py・build_gsn.py・PGSN）をブラウザ上で動かす。
// 一式は flask リポジトリの tools/build_pyodide_bundle.py で web/pgsn/ に作る。

import 'dart:convert';
import 'dart:js_interop';

@JS('pgsnEval')
external _PgsnEval? get _pgsnEval;

extension type _PgsnEval._(JSObject _) implements JSObject {
  external JSPromise<JSString> preload();
  external JSPromise<JSString> evaluate(JSString requestJson);
}

/// ブラウザ内評価の結果。
class BrowserEvalResult {
  BrowserEvalResult(this.body, this.evalMs);

  /// 評価結果の図（nodes/edges）。形式の誤りは {"error": ...}
  final Map<String, dynamic> body;

  /// Python での評価にかかった時間（読み込み時間は含まない）
  final double evalMs;
}

class BrowserEval {
  /// Pyodide とPGSNを先に読み込んでおく（最初の評価を待たせないため）。失敗しても無視する
  /// （評価のときにもう一度読み込む）。
  static void preload() {
    final eval = _pgsnEval;
    if (eval == null) return;
    eval.preload().toDart.then((_) {}, onError: (_) {});
  }

  /// 評価する。Pyodide を読み込めないなど、評価できないときは例外を投げる。
  static Future<BrowserEvalResult> evaluate(String requestJson) async {
    final eval = _pgsnEval;
    if (eval == null) throw StateError('ブラウザ内評価が読み込まれていません');
    final reply = jsonDecode((await eval.evaluate(requestJson.toJS).toDart).toDart)
        as Map<String, dynamic>;
    return BrowserEvalResult(
      jsonDecode(reply['result'] as String) as Map<String, dynamic>,
      (reply['evalMs'] as num).toDouble(),
    );
  }
}
