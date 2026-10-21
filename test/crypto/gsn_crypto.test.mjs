// web/crypto/gsn_crypto.js のテスト（Node の WebCrypto で動かす）
//   node --test test/crypto/
import test from "node:test";
import assert from "node:assert/strict";
import c, { normalizeRecoveryKey } from "../../web/crypto/gsn_crypto.js";

const UID = "user-a";
const PASS = "correct horse battery";

async function freshSetup(uid = UID, pass = PASS) {
  c.lock();
  return JSON.parse(await c.setupKeyring(uid, pass));
}

const rejectsWith = (p, code) => assert.rejects(p, (e) => e.message.startsWith(code + ":"));

test("初回設定のあと、暗号化と復号が往復できる", async () => {
  await freshSetup();
  const item = await c.encryptItem(UID, "diagrams", "doc1", '{"name":"図","content":"本文"}');
  assert.ok(!item.includes("本文") && !item.includes("図"));
  assert.equal(await c.decryptItem(UID, "diagrams", "doc1", item), '{"name":"図","content":"本文"}');
});

test("同じ中身でも毎回違う暗号文になる", async () => {
  await freshSetup();
  const a = await c.encryptItem(UID, "diagrams", "d", "x");
  const b = await c.encryptItem(UID, "diagrams", "d", "x");
  assert.notEqual(a, b);
});

test("ロック後に正しいパスフレーズで解除でき、違うパスフレーズでは失敗する", async () => {
  const { keyring } = await freshSetup();
  const item = await c.encryptItem(UID, "csvFiles", "c1", "a,b\n1,2");
  c.lock();
  await rejectsWith(c.decryptItem(UID, "csvFiles", "c1", item), "LOCKED");
  await rejectsWith(c.unlockWithPassphrase(UID, keyring, "wrong passphrase!!"), "WRONG_SECRET");
  await c.unlockWithPassphrase(UID, JSON.stringify(keyring), PASS);
  assert.equal(await c.decryptItem(UID, "csvFiles", "c1", item), "a,b\n1,2");
});

test("回復キーで解除して新しいパスフレーズに包み直せる（データはそのまま読める）", async () => {
  const { keyring, recoveryKey } = await freshSetup();
  assert.match(recoveryKey, /^([A-Z2-7]{4}-){7}[A-Z2-7]{4}$/);
  const item = await c.encryptItem(UID, "diagrams", "d1", "hello");
  c.lock();
  // 小文字・空白入り・ハイフンなしでも受け付ける
  await c.unlockWithRecoveryKey(UID, keyring, " " + recoveryKey.replace(/-/g, "").toLowerCase() + " ");
  const newKeyring = JSON.parse(await c.rewrapPassphrase(UID, keyring, "a brand new passphrase"));
  assert.deepEqual(newKeyring.recovery, keyring.recovery);
  c.lock();
  await rejectsWith(c.unlockWithPassphrase(UID, newKeyring, PASS), "WRONG_SECRET");
  await c.unlockWithPassphrase(UID, newKeyring, "a brand new passphrase");
  assert.equal(await c.decryptItem(UID, "diagrams", "d1", item), "hello");
});

test("違う回復キーでは解除できない", async () => {
  const { keyring } = await freshSetup();
  c.lock();
  await rejectsWith(c.unlockWithRecoveryKey(UID, keyring, "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"), "WRONG_SECRET");
  await rejectsWith(c.unlockWithRecoveryKey(UID, keyring, "too-short"), "WRONG_SECRET");
});

test("改ざん・ドキュメントの入れ替え・別のコレクションへの付け替えを検知する", async () => {
  await freshSetup();
  const item = JSON.parse(await c.encryptItem(UID, "diagrams", "d1", "secret"));
  const flipped = { ...item, ct: item.ct.slice(0, -4) + (item.ct.endsWith("AAA=") ? "BAA=" : "AAA=") };
  await rejectsWith(c.decryptItem(UID, "diagrams", "d1", flipped), "TAMPERED");
  await rejectsWith(c.decryptItem(UID, "diagrams", "d2", item), "TAMPERED");
  await rejectsWith(c.decryptItem(UID, "csvFiles", "d1", item), "TAMPERED");
});

test("別のアカウントの鍵ではそのアカウントのデータを扱えない", async () => {
  const a = await freshSetup("user-a");
  const item = await c.encryptItem("user-a", "diagrams", "d1", "a's data");
  await rejectsWith(c.encryptItem("user-b", "diagrams", "d1", "x"), "LOCKED");
  // user-b の鍵の情報として user-a の鍵の情報を使っても解除できない（uid が AAD に入っている）
  c.lock();
  await rejectsWith(c.unlockWithPassphrase("user-b", a.keyring, PASS), "WRONG_SECRET");
  await c.unlockWithPassphrase("user-a", a.keyring, PASS);
  assert.equal(await c.decryptItem("user-a", "diagrams", "d1", item), "a's data");
});

test("短いパスフレーズは受け付けない", async () => {
  c.lock();
  await rejectsWith(c.setupKeyring(UID, "short"), "WEAK_PASSPHRASE");
  await freshSetup();
  const { keyring } = await freshSetup();
  await rejectsWith(c.rewrapPassphrase(UID, keyring, "12345678901"), "WEAK_PASSPHRASE");
});

test("鍵の情報にパスフレーズや主鍵がそのまま入っていない", async () => {
  const { keyring } = await freshSetup();
  const text = JSON.stringify(keyring);
  assert.ok(!text.includes(PASS));
  assert.equal(keyring.pass.iter, 600000);
  assert.deepEqual(Object.keys(keyring).sort(), ["pass", "recovery", "v"]);
});

test("回復キーの正規化", () => {
  assert.equal(normalizeRecoveryKey("abcd-0181-2345-6723-4567-2345-6723-4567"), "ABCDOIBI234567234567234567234567");
});

// ---- パスキー（第1b段階）----
import { installFakePasskeys } from "./fake_passkey.mjs";

test("パスキーを登録すると、パスキーで解除できる（パスフレーズ・回復キーもそのまま使える）", async () => {
  const fake = installFakePasskeys();
  const { keyring } = await freshSetup();
  const item = await c.encryptItem(UID, "diagrams", "d1", "with passkey");
  const k2 = JSON.parse(await c.registerPasskey(UID, keyring, "a@example.test", "MacBook"));
  assert.equal(fake.calls.create, 1);
  assert.equal(fake.calls.get, 1); // 作成時に PRF の値が出ないので、もう一度評価している
  const ids = Object.keys(k2.passkeys);
  assert.equal(ids.length, 1);
  assert.equal(k2.passkeys[ids[0]].label, "MacBook");
  assert.deepEqual(k2.pass, keyring.pass);
  assert.deepEqual(k2.recovery, keyring.recovery);
  c.lock();
  await c.unlockWithPasskey(UID, k2);
  assert.equal(await c.decryptItem(UID, "diagrams", "d1", item), "with passkey");
  c.lock();
  await c.unlockWithPassphrase(UID, k2, PASS);
});

test("パスキーの操作を取り消すと CANCELLED、PRF 非対応なら PRF_UNSUPPORTED", async () => {
  let fake = installFakePasskeys();
  const { keyring } = await freshSetup();
  fake.cancelNext = true;
  await rejectsWith(c.registerPasskey(UID, keyring, "a", "x"), "CANCELLED");
  installFakePasskeys(globalThis, { prf: false });
  await rejectsWith(c.registerPasskey(UID, keyring, "a", "x"), "PRF_UNSUPPORTED");
});

test("別のパスキーの PRF の値や、別アカウントでは解除できない", async () => {
  installFakePasskeys();
  const { keyring } = await freshSetup();
  const k2 = JSON.parse(await c.registerPasskey(UID, keyring, "a", "x"));
  const id = Object.keys(k2.passkeys)[0];
  c.lock();
  const wrong = btoa(String.fromCharCode(...new Uint8Array(32)));
  await rejectsWith(c.unlockWithPasskeyOutput(UID, k2, id, wrong), "WRONG_SECRET");
  await rejectsWith(c.unlockWithPasskey("user-b", k2), "WRONG_SECRET");
});

test("パスフレーズを変えてもパスキーの登録は残る", async () => {
  installFakePasskeys();
  const { keyring } = await freshSetup();
  const k2 = JSON.parse(await c.registerPasskey(UID, keyring, "a", "x"));
  const k3 = JSON.parse(await c.rewrapPassphrase(UID, k2, "yet another passphrase"));
  assert.deepEqual(k3.passkeys, k2.passkeys);
  c.lock();
  await c.unlockWithPasskey(UID, k3);
});
