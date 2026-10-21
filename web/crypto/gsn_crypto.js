// アカウントに保存する図・CSVのエンドツーエンド暗号化（設計は docs/encryption-design.md）。
// 鍵はブラウザのメモリにだけ置き、Firestore には暗号化した形（包んだ鍵・暗号文）しか送らない。
//
// 鍵の構成:
//   暗号化パスフレーズ ─PBKDF2─▶ KEK ─┐
//   回復キー           ─HKDF───▶ KEK ─┼─ MK（利用者の主鍵）を包む
//   パスキー（PRF）    ─HKDF───▶ KEK ─┘  パスキーごとに1つ
//   MK ─▶ 図・CSV 1件ごとの DEK を包む ─▶ DEK で本文を暗号化
//
// Dart（lib/crypto_service.dart）からは window.gsnCrypto として呼ぶ。値の受け渡しは文字列（JSON）だけ。
// 失敗の理由は Error.message の先頭に付けたコード（WRONG_SECRET など）で返す。

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

const FORMAT_VERSION = 1;
const PBKDF2_ITERATIONS = 600000;
const MIN_PASSPHRASE_LENGTH = 12;
const RECOVERY_KEY_BYTES = 20; // Base32 で32文字
const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

// 解除中の主鍵と、その持ち主の uid（別のアカウントのデータに使わないため）
let unlocked = null; // { uid, mk: CryptoKey }

// ---- 小さな道具 ----

function fail(code, message) {
  return new Error(`${code}: ${message}`);
}

function randomBytes(n) {
  return globalThis.crypto.getRandomValues(new Uint8Array(n));
}

function toBase64(bytes) {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s);
}

function fromBase64(text) {
  if (typeof text !== "string") throw fail("BAD_FORMAT", "データの形式が正しくありません");
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function toBase64Url(bytes) {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64Url(text) {
  const s = String(text).replace(/-/g, "+").replace(/_/g, "/");
  return fromBase64(s + "=".repeat((4 - (s.length % 4)) % 4));
}

function base32Encode(bytes) {
  let bits = 0, value = 0, out = "";
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

function base32Decode(text) {
  let bits = 0, value = 0;
  const out = [];
  for (const ch of text) {
    const i = BASE32.indexOf(ch);
    if (i < 0) throw fail("WRONG_SECRET", "回復キーに使えない文字が含まれています");
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

/** 回復キーを表示用に4文字ずつ区切る */
function formatRecoveryKey(raw) {
  return raw.match(/.{1,4}/g).join("-");
}

/** 入力された回復キーを正規化する（空白・ハイフンを無視し、読み間違えやすい 0/1/8 を O/I/B とみなす） */
function normalizeRecoveryKey(input) {
  const s = String(input).toUpperCase().replace(/[\s-]/g, "")
    .replace(/0/g, "O").replace(/1/g, "I").replace(/8/g, "B");
  if (s.length !== 32) throw fail("WRONG_SECRET", "回復キーは32文字です");
  return s;
}

function aad(...parts) {
  return enc.encode(["gsnpaint", `v${FORMAT_VERSION}`, ...parts].join(":"));
}

// AES-GCM で暗号化・復号する。AAD（付加データ）が違うと復号に失敗する
async function seal(key, plaintext, additionalData) {
  const iv = randomBytes(12);
  const ct = await subtle.encrypt({ name: "AES-GCM", iv, additionalData }, key, plaintext);
  return { iv: toBase64(iv), ct: toBase64(ct) };
}

async function open(key, box, additionalData, errorCode) {
  try {
    return new Uint8Array(await subtle.decrypt(
      { name: "AES-GCM", iv: fromBase64(box.iv), additionalData }, key, fromBase64(box.ct)));
  } catch (e) {
    if (e.message && e.message.startsWith("BAD_FORMAT")) throw e;
    throw fail(errorCode, "復号できませんでした");
  }
}

function importAesKey(raw, extractable) {
  return subtle.importKey("raw", raw, { name: "AES-GCM" }, extractable, ["encrypt", "decrypt"]);
}

// ---- 鍵を包む鍵（KEK）----

async function passphraseKek(passphrase, saltB64, iterations) {
  const base = await subtle.importKey("raw", enc.encode(passphrase), "PBKDF2", false, ["deriveKey"]);
  return subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt: fromBase64(saltB64), iterations },
    base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

async function recoveryKek(recoveryKey, saltB64) {
  const base = await subtle.importKey(
    "raw", base32Decode(normalizeRecoveryKey(recoveryKey)), "HKDF", false, ["deriveKey"]);
  return subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: fromBase64(saltB64), info: enc.encode("gsnpaint recovery key") },
    base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

// パスキーの PRF 拡張が返す秘密の値（32バイト）から KEK を作る
async function passkeyKek(prfOutput, prfSaltB64) {
  const base = await subtle.importKey("raw", prfOutput, "HKDF", false, ["deriveKey"]);
  return subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: fromBase64(prfSaltB64), info: enc.encode("gsnpaint passkey") },
    base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

function checkPassphrase(passphrase) {
  if (typeof passphrase !== "string" || [...passphrase].length < MIN_PASSPHRASE_LENGTH) {
    throw fail("WEAK_PASSPHRASE", `パスフレーズは${MIN_PASSPHRASE_LENGTH}文字以上にしてください`);
  }
}

async function wrapMkWithPassphrase(uid, mkRaw, passphrase) {
  const salt = toBase64(randomBytes(16));
  const kek = await passphraseKek(passphrase, salt, PBKDF2_ITERATIONS);
  const box = await seal(kek, mkRaw, aad("keyring", uid, "pass"));
  return { kdf: "PBKDF2-SHA256", salt, iter: PBKDF2_ITERATIONS, iv: box.iv, wrappedMk: box.ct };
}

function parseKeyring(keyringJson) {
  const k = typeof keyringJson === "string" ? JSON.parse(keyringJson) : keyringJson;
  if (!k || k.v !== FORMAT_VERSION || !k.pass || !k.recovery) {
    throw fail("BAD_FORMAT", "鍵の情報の形式が正しくありません");
  }
  return k;
}

async function setUnlocked(uid, mkRaw) {
  // 包み直し（パスフレーズの変更）に使うため、主鍵は取り出し可能にしておく（メモリの中だけ）
  unlocked = { uid, mk: await importAesKey(mkRaw, true) };
}

function requireUnlocked(uid) {
  if (!unlocked) throw fail("LOCKED", "暗号化の解除が必要です");
  if (unlocked.uid !== uid) throw fail("LOCKED", "別のアカウントの鍵が解除されています");
  return unlocked.mk;
}

// ---- 公開する操作 ----

/** 初めて使うとき: 主鍵と回復キーを作り、解除した状態にする。{keyring, recoveryKey} の JSON を返す */
async function setupKeyring(uid, passphrase) {
  checkPassphrase(passphrase);
  const mkRaw = randomBytes(32);
  const recoveryRaw = base32Encode(randomBytes(RECOVERY_KEY_BYTES));
  const recoverySalt = toBase64(randomBytes(16));
  const rbox = await seal(await recoveryKek(recoveryRaw, recoverySalt), mkRaw, aad("keyring", uid, "recovery"));
  const keyring = {
    v: FORMAT_VERSION,
    pass: await wrapMkWithPassphrase(uid, mkRaw, passphrase),
    recovery: { kdf: "HKDF-SHA256", salt: recoverySalt, iv: rbox.iv, wrappedMk: rbox.ct },
  };
  await setUnlocked(uid, mkRaw);
  return JSON.stringify({ keyring, recoveryKey: formatRecoveryKey(recoveryRaw) });
}

/** パスフレーズで解除する */
async function unlockWithPassphrase(uid, keyringJson, passphrase) {
  const k = parseKeyring(keyringJson);
  const kek = await passphraseKek(passphrase, k.pass.salt, k.pass.iter);
  const mkRaw = await open(kek, { iv: k.pass.iv, ct: k.pass.wrappedMk }, aad("keyring", uid, "pass"), "WRONG_SECRET");
  await setUnlocked(uid, mkRaw);
}

/** 回復キーで解除する（このあと rewrapPassphrase で新しいパスフレーズを設定する） */
async function unlockWithRecoveryKey(uid, keyringJson, recoveryKey) {
  const k = parseKeyring(keyringJson);
  const kek = await recoveryKek(recoveryKey, k.recovery.salt);
  const mkRaw = await open(kek, { iv: k.recovery.iv, ct: k.recovery.wrappedMk }, aad("keyring", uid, "recovery"), "WRONG_SECRET");
  await setUnlocked(uid, mkRaw);
}

/** 解除中の主鍵を新しいパスフレーズで包み直し、新しい鍵の情報（JSON）を返す。データの再暗号化は不要 */
async function rewrapPassphrase(uid, keyringJson, newPassphrase) {
  checkPassphrase(newPassphrase);
  const mk = requireUnlocked(uid);
  const k = parseKeyring(keyringJson);
  const mkRaw = new Uint8Array(await subtle.exportKey("raw", mk));
  return JSON.stringify({ ...k, pass: await wrapMkWithPassphrase(uid, mkRaw, newPassphrase) });
}

/**
 * 解除中の主鍵を、パスキーの PRF の値で包んで keyring に加える（新しい鍵の情報の JSON を返す）。
 * credId はパスキーの ID（base64url）、prfOutputB64 はそのパスキーで prfSaltB64 を評価した結果。
 */
async function addPasskeyWrap(uid, keyringJson, credId, prfSaltB64, prfOutputB64, label) {
  const mk = requireUnlocked(uid);
  const k = parseKeyring(keyringJson);
  const mkRaw = new Uint8Array(await subtle.exportKey("raw", mk));
  const kek = await passkeyKek(fromBase64(prfOutputB64), prfSaltB64);
  const box = await seal(kek, mkRaw, aad("keyring", uid, "passkey", credId));
  const passkeys = { ...(k.passkeys || {}) };
  passkeys[credId] = {
    prfSalt: prfSaltB64, iv: box.iv, wrappedMk: box.ct,
    label: String(label || "パスキー").slice(0, 60), createdAt: new Date().toISOString(),
  };
  return JSON.stringify({ ...k, passkeys });
}

/** パスキーの PRF の値で解除する */
async function unlockWithPasskeyOutput(uid, keyringJson, credId, prfOutputB64) {
  const k = parseKeyring(keyringJson);
  const entry = k.passkeys && k.passkeys[credId];
  if (!entry) throw fail("WRONG_SECRET", "このパスキーは登録されていません");
  const kek = await passkeyKek(fromBase64(prfOutputB64), entry.prfSalt);
  const mkRaw = await open(kek, { iv: entry.iv, ct: entry.wrappedMk }, aad("keyring", uid, "passkey", credId), "WRONG_SECRET");
  await setUnlocked(uid, mkRaw);
}

// ---- パスキー（WebAuthn の PRF 拡張）----
// 署名の検証は行わない（サーバがないため）。守りは PRF の値にある: この値はパスキー（端末の
// 認証器）でしか計算できず、それがないと主鍵を包んだ箱を開けられない。

function webauthnError(e) {
  if (e && e.message && /^[A-Z_]+: /.test(e.message)) return e;
  if (e && e.name === "NotAllowedError") return fail("CANCELLED", "パスキーの操作が取り消されたか、時間切れになりました");
  if (e && e.name === "InvalidStateError") return fail("CANCELLED", "このパスキーはすでに登録されています");
  return fail("PASSKEY_FAILED", `パスキーを使えませんでした（${(e && e.name) || e}）`);
}

/** この端末・ブラウザでパスキーの PRF を使えそうか（最終的には登録してみないと分からない） */
async function passkeySupported() {
  if (!globalThis.PublicKeyCredential || !navigator.credentials) return false;
  try {
    const caps = await PublicKeyCredential.getClientCapabilities?.();
    if (caps && "extension:prf" in caps) return caps["extension:prf"] === true;
  } catch (_) { /* 古いブラウザ */ }
  return true;
}

// パスキーで prfSalt を評価して、PRF の値（base64）を得る
async function evaluatePrf(credIds, saltsByCred) {
  const evalByCredential = {};
  for (const id of credIds) evalByCredential[id] = { first: fromBase64(saltsByCred[id]) };
  let cred;
  try {
    cred = await navigator.credentials.get({ publicKey: {
      challenge: randomBytes(32),
      allowCredentials: credIds.map((id) => ({ type: "public-key", id: fromBase64Url(id) })),
      userVerification: "required",
      extensions: { prf: { evalByCredential } },
    } });
  } catch (e) {
    throw webauthnError(e);
  }
  const first = cred && cred.getClientExtensionResults().prf?.results?.first;
  if (!first) throw fail("PRF_UNSUPPORTED", "このパスキーは暗号化の解除に対応していません");
  return { credId: toBase64Url(cred.rawId), output: toBase64(first) };
}

/** パスキーを新しく作り、解除中の主鍵をそれで包む。新しい鍵の情報（JSON）を返す */
async function registerPasskey(uid, keyringJson, userName, label) {
  requireUnlocked(uid);
  const k = parseKeyring(keyringJson);
  const prfSalt = randomBytes(32);
  let cred;
  try {
    cred = await navigator.credentials.create({ publicKey: {
      rp: { name: "GSNエディタ" },
      user: { id: enc.encode(uid), name: userName || uid, displayName: userName || "GSNエディタ" },
      challenge: randomBytes(32),
      pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
      authenticatorSelection: { residentKey: "preferred", userVerification: "required" },
      excludeCredentials: Object.keys(k.passkeys || {}).map((id) => ({ type: "public-key", id: fromBase64Url(id) })),
      extensions: { prf: { eval: { first: prfSalt } } },
    } });
  } catch (e) {
    throw webauthnError(e);
  }
  const ext = cred.getClientExtensionResults().prf;
  if (!ext || ext.enabled === false) {
    throw fail("PRF_UNSUPPORTED", "このパスキー（端末・パスワード管理アプリ）は暗号化の解除に対応していません");
  }
  const credId = toBase64Url(cred.rawId);
  const saltB64 = toBase64(prfSalt);
  // 作成時に PRF の値を返さない認証器が多いので、その場合はもう一度パスキーで評価する
  let output = ext.results?.first ? toBase64(ext.results.first) : null;
  if (!output) output = (await evaluatePrf([credId], { [credId]: saltB64 })).output;
  return addPasskeyWrap(uid, k, credId, saltB64, output, label);
}

/** 登録済みのパスキーのどれかで解除する */
async function unlockWithPasskey(uid, keyringJson) {
  const k = parseKeyring(keyringJson);
  const ids = Object.keys(k.passkeys || {});
  if (ids.length === 0) throw fail("WRONG_SECRET", "パスキーが登録されていません");
  const salts = Object.fromEntries(ids.map((id) => [id, k.passkeys[id].prfSalt]));
  const { credId, output } = await evaluatePrf(ids, salts);
  await unlockWithPasskeyOutput(uid, k, credId, output);
}

function lock() {
  unlocked = null;
}

function unlockedUid() {
  return unlocked ? unlocked.uid : null;
}

/** 1件を暗号化する。docId はこのデータを置く Firestore のドキュメントID（入れ替えの検知に使う） */
async function encryptItem(uid, collection, docId, plaintext) {
  const mk = requireUnlocked(uid);
  const dekRaw = randomBytes(32);
  const wrappedDek = await seal(mk, dekRaw, aad("dek", uid, collection, docId));
  const body = await seal(await importAesKey(dekRaw, false), enc.encode(plaintext), aad("item", uid, collection, docId));
  return JSON.stringify({ v: FORMAT_VERSION, wrappedDek, iv: body.iv, ct: body.ct });
}

/** 1件を復号して元の文字列を返す */
async function decryptItem(uid, collection, docId, itemJson) {
  const mk = requireUnlocked(uid);
  const item = typeof itemJson === "string" ? JSON.parse(itemJson) : itemJson;
  if (!item || item.v !== FORMAT_VERSION || !item.wrappedDek) {
    throw fail("BAD_FORMAT", "暗号化データの形式が正しくありません");
  }
  const dekRaw = await open(mk, item.wrappedDek, aad("dek", uid, collection, docId), "TAMPERED");
  const body = await open(await importAesKey(dekRaw, false), item, aad("item", uid, collection, docId), "TAMPERED");
  return dec.decode(body);
}

const api = {
  setupKeyring, unlockWithPassphrase, unlockWithRecoveryKey, rewrapPassphrase,
  addPasskeyWrap, unlockWithPasskeyOutput, passkeySupported, registerPasskey, unlockWithPasskey,
  lock, unlockedUid, encryptItem, decryptItem,
};

// Dart から呼ぶ窓口。失敗しても Promise は reject せず、
// {"ok": true, "value": ...} か {"ok": false, "code": ..., "message": ...} の JSON 文字列で返す
// （JS の例外を Dart 側で解釈しなくて済むように）。
globalThis.gsnCrypto = Object.fromEntries(Object.entries(api).map(([name, fn]) => [name, async (...args) => {
  try {
    return JSON.stringify({ ok: true, value: (await fn(...args)) ?? null });
  } catch (e) {
    const m = /^([A-Z_]+): (.*)$/s.exec(String(e && e.message));
    return JSON.stringify(m ? { ok: false, code: m[1], message: m[2] }
                            : { ok: false, code: "UNKNOWN", message: String(e && e.message || e) });
  }
}]));

export default api;
export { normalizeRecoveryKey, MIN_PASSPHRASE_LENGTH };
