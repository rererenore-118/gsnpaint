// アカウントに保存する図・CSVのエンドツーエンド暗号化（設計は docs/encryption-design.md）。
// 鍵はブラウザのメモリにだけ置き、Firestore には暗号化した形（包んだ鍵・暗号文）しか送らない。
//
// 鍵の構成:
//   暗号化パスフレーズ ─PBKDF2─▶ KEK ─┐
//   回復キー           ─HKDF───▶ KEK ─┴─ MK（利用者の主鍵）を包む
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
