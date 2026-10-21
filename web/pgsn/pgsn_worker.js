// ブラウザ内でPGSNの評価を行う Web Worker。
// Pyodide（WebAssembly版のPython）を読み込み、評価サーバと同じ gsn_eval.py を動かす。
// 画面とは別のスレッドで動くので、評価中もエディタの画面は固まらない。
// モジュール形式の Worker として起動する（pgsn_eval.js の type: "module"）。

// Pyodide本体も同じサイトの pyodide/ に置いてあり、外部のサーバやCDNは使わない。
import { loadPyodide } from "./pyodide/pyodide.mjs";

const PYODIDE_BASE = new URL("./pyodide/", self.location).href;
const APP_DIR = "/home/pyodide/pgsn_app";

let ready = null;

async function init() {
  const started = performance.now();
  const pyodide = await loadPyodide({ indexURL: PYODIDE_BASE });

  // 同じフォルダの manifest.json に、同梱したwheelとアプリ本体のzipが書いてある
  const manifest = await (await fetch("manifest.json", { cache: "no-cache" })).json();
  await pyodide.loadPackage(manifest.wheels.map((w) => new URL(w, self.location).href));

  const app = await fetch(manifest.app, { cache: "no-cache" });
  if (!app.ok) throw new Error(`${manifest.app} を読み込めません (${app.status})`);
  pyodide.unpackArchive(await app.arrayBuffer(), "zip", { extractDir: APP_DIR });
  pyodide.runPython(`
import sys
sys.path.insert(0, "${APP_DIR}")
import gsn_eval
`);
  const evaluateJson = pyodide.globals.get("gsn_eval").evaluate_json;
  return { evaluateJson, initMs: performance.now() - started };
}

self.onmessage = async (event) => {
  const { id, type, payload } = event.data;
  try {
    // 読み込みに失敗したら、次の呼び出しでやり直せるようにする
    ready ??= init().catch((e) => { ready = null; throw e; });
    const { evaluateJson, initMs } = await ready;
    if (type === "preload") {
      self.postMessage({ id, ok: true, initMs });
      return;
    }
    const started = performance.now();
    const result = evaluateJson(payload);
    self.postMessage({ id, ok: true, result, evalMs: performance.now() - started, initMs });
  } catch (e) {
    self.postMessage({ id, ok: false, error: String(e && e.message ? e.message : e) });
  }
};
