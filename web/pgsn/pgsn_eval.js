// エディタ（Dart）からブラウザ内評価を呼ぶための窓口。
// 実際の評価は pgsn_worker.js（Web Worker）が行う。
//   pgsnEval.preload()          … Pyodide とPGSNを先に読み込んでおく
//   pgsnEval.evaluate(json)     … 評価する。{"result": ..., "evalMs": ..., "initMs": ...} のJSON文字列を返す
(function () {
  let worker = null;
  let nextId = 0;
  const pending = new Map();

  function getWorker() {
    if (worker) return worker;
    worker = new Worker(new URL("pgsn/pgsn_worker.js", document.baseURI), { type: "module" });
    worker.onmessage = (event) => {
      const { id, ok, error, ...rest } = event.data;
      const p = pending.get(id);
      if (!p) return;
      pending.delete(id);
      ok ? p.resolve(JSON.stringify(rest)) : p.reject(new Error(error));
    };
    worker.onerror = (event) => {
      // Worker自体が起動できない（pyodide.js を読み込めない等）。待っている呼び出しをすべて失敗にする
      const err = new Error(event.message || "ブラウザ内評価を起動できません");
      pending.forEach((p) => p.reject(err));
      pending.clear();
      worker = null;
    };
    return worker;
  }

  function call(type, payload) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      getWorker().postMessage({ id, type, payload });
    });
  }

  window.pgsnEval = {
    preload: () => call("preload"),
    evaluate: (requestJson) => call("evaluate", requestJson),
  };
})();
