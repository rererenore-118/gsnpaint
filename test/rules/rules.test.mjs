// firestore.rules のテスト。Firestore エミュレータの中で動かす:
//   cd test/rules && npm install && npm test
// 暗号化したデータは本物の web/crypto/gsn_crypto.js で作る。
import test, { before, after, beforeEach } from "node:test";
import { readFileSync } from "node:fs";
import { initializeTestEnvironment, assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import { doc, getDoc, getDocs, collection, setDoc, updateDoc, deleteDoc, serverTimestamp, Timestamp } from "firebase/firestore";
import c from "../../web/crypto/gsn_crypto.js";

let env;
const ALICE = "alice", BOB = "bob";

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-gsnpaint",
    firestore: { rules: readFileSync(new URL("../../firestore.rules", import.meta.url), "utf8") },
  });
});
after(() => env.cleanup());
beforeEach(() => env.clearFirestore());

const db = (uid, verified = true) =>
  env.authenticatedContext(uid, { email_verified: verified }).firestore();

async function keyringFor(uid) {
  c.lock();
  return JSON.parse(await c.setupKeyring(uid, "passphrase for tests")).keyring;
}

async function encryptedItem(uid, col, id, name = "図", content = "{}") {
  return { ...JSON.parse(await c.encryptItem(uid, col, id, JSON.stringify({ name, content }))),
           updatedAt: serverTimestamp() };
}

test("本人は鍵の情報を作れる。他人・未確認のアカウントは作れない", async () => {
  const k = await keyringFor(ALICE);
  await assertFails(setDoc(doc(db(BOB), `users/${ALICE}/crypto/keyring`), { ...k, createdAt: serverTimestamp() }));
  await assertFails(setDoc(doc(db(ALICE, false), `users/${ALICE}/crypto/keyring`), { ...k, createdAt: serverTimestamp() }));
  await assertSucceeds(setDoc(doc(db(ALICE), `users/${ALICE}/crypto/keyring`), { ...k, createdAt: serverTimestamp() }));
  await assertFails(getDoc(doc(db(BOB), `users/${ALICE}/crypto/keyring`)));
});

test("鍵の情報: 形が違う・反復回数が少ないものは作れない", async () => {
  const k = await keyringFor(ALICE);
  const ref = doc(db(ALICE), `users/${ALICE}/crypto/keyring`);
  await assertFails(setDoc(ref, { ...k, createdAt: serverTimestamp(), extra: "x" }));
  await assertFails(setDoc(ref, { ...k, pass: { ...k.pass, iter: 1000 }, createdAt: serverTimestamp() }));
  await assertFails(setDoc(ref, { ...k, createdAt: Timestamp.fromMillis(0) }));
});

test("鍵の情報: パスフレーズ側の包み直しはできるが、回復キー側は変えられない", async () => {
  const k = await keyringFor(ALICE);
  const ref = doc(db(ALICE), `users/${ALICE}/crypto/keyring`);
  await assertSucceeds(setDoc(ref, { ...k, createdAt: serverTimestamp() }));
  const k2 = JSON.parse(await c.rewrapPassphrase(ALICE, JSON.stringify(k), "another passphrase!"));
  await assertSucceeds(updateDoc(ref, { pass: k2.pass, updatedAt: serverTimestamp() }));
  const other = await keyringFor(ALICE);
  await assertFails(updateDoc(ref, { recovery: other.recovery }));
});

test("図・CSV: 暗号化した形なら本人だけが書ける", async () => {
  await keyringFor(ALICE);
  for (const col of ["diagrams", "csvFiles"]) {
    const item = await encryptedItem(ALICE, col, "d1");
    await assertSucceeds(setDoc(doc(db(ALICE), `users/${ALICE}/${col}/d1`), item));
    await assertFails(setDoc(doc(db(BOB), `users/${ALICE}/${col}/d2`), item));
    await assertFails(getDoc(doc(db(BOB), `users/${ALICE}/${col}/d1`)));
    await assertSucceeds(getDoc(doc(db(ALICE), `users/${ALICE}/${col}/d1`)));
  }
});

test("図・CSV: 平文の名前や本文は書けない（暗号文に足すことも）", async () => {
  await keyringFor(ALICE);
  const ref = doc(db(ALICE), `users/${ALICE}/diagrams/d1`);
  await assertFails(setDoc(ref, { name: "図", content: "{}", updatedAt: serverTimestamp() }));
  const item = await encryptedItem(ALICE, "diagrams", "d1");
  await assertFails(setDoc(ref, { ...item, name: "図" }));
  await assertFails(setDoc(ref, { ...item, v: 2 }));
  const { wrappedDek, ...noDek } = item;
  await assertFails(setDoc(ref, noDek));
});

test("暗号化前の平文データは、本人が読み出して削除できる（移行のため）", async () => {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), `users/${ALICE}/diagrams/old`), { name: "古い図", content: "{}" });
  });
  await assertSucceeds(getDoc(doc(db(ALICE), `users/${ALICE}/diagrams/old`)));
  await assertFails(updateDoc(doc(db(ALICE), `users/${ALICE}/diagrams/old`), { content: "{ }" }));
  await assertSucceeds(deleteDoc(doc(db(ALICE), `users/${ALICE}/diagrams/old`)));
});

test("決められた場所以外には書けない", async () => {
  await keyringFor(ALICE);
  const item = await encryptedItem(ALICE, "other", "x");
  await assertFails(setDoc(doc(db(ALICE), `users/${ALICE}/other/x`), item));
  await assertFails(setDoc(doc(db(ALICE), `users/${ALICE}`), { a: 1 }));
});

test("鍵の情報: パスキーを10件まで足せる。11件以上は書けない", async () => {
  const k = await keyringFor(ALICE);
  const ref = doc(db(ALICE), `users/${ALICE}/crypto/keyring`);
  await assertSucceeds(setDoc(ref, { ...k, createdAt: serverTimestamp() }));
  const entry = { prfSalt: "c2FsdA==", iv: "aXY=", wrappedMk: "bWs=", label: "x", createdAt: "2026-10-21T00:00:00Z" };
  const many = (n) => Object.fromEntries([...Array(n)].map((_, i) => [`cred${i}`, entry]));
  await assertSucceeds(updateDoc(ref, { passkeys: many(10), updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(ref, { passkeys: many(11), updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(ref, { passkeys: "not a map" }));
});

test("図の過去の版: 暗号化した形で本人だけが作れる。書き換えはできない", async () => {
  await keyringFor(ALICE);
  const path = `users/${ALICE}/diagrams/d1/versions/v1`;
  const item = await encryptedItem(ALICE, "diagrams/d1/versions", "v1");
  await assertFails(setDoc(doc(db(BOB), path), item));
  await assertFails(setDoc(doc(db(ALICE), path), { name: "図", content: "{}", updatedAt: serverTimestamp() }));
  await assertSucceeds(setDoc(doc(db(ALICE), path), item));
  await assertFails(setDoc(doc(db(ALICE), path), await encryptedItem(ALICE, "diagrams/d1/versions", "v1")));
  await assertFails(getDoc(doc(db(BOB), path)));
  await assertSucceeds(getDoc(doc(db(ALICE), path)));
  await assertSucceeds(deleteDoc(doc(db(ALICE), path)));
  // CSV の下には版を作れない
  await assertFails(setDoc(doc(db(ALICE), `users/${ALICE}/csvFiles/c1/versions/v1`), item));
});

// ---- 評価実験のアンケート ----
const SURVEY = "surveys/editor-eval-v1/responses";
const surveyAnswers = (over = {}) => ({
  gsn_exp: "seen", prog_exp: "1to3",
  sus1: 4, sus2: 2, sus3: 4, sus4: 1, sus5: 4, sus6: 2, sus7: 5, sus8: 2, sus9: 4, sus10: 3,
  good: "", bad: "", ...over,
});
const surveyDoc = (over = {}, answers = {}) =>
  ({ participantId: "P01", answers: surveyAnswers(answers), submittedAt: serverTimestamp(), ...over });

test("アンケート: 本人は 1 回だけ答えられ、書き換え・削除はできない", async () => {
  const ref = doc(db(ALICE), `${SURVEY}/${ALICE}`);
  await assertFails(setDoc(doc(db(BOB), `${SURVEY}/${ALICE}`), surveyDoc()));
  await assertFails(setDoc(doc(db(ALICE, false), `${SURVEY}/${ALICE}`), surveyDoc()));
  await assertFails(setDoc(doc(env.unauthenticatedContext().firestore(), `${SURVEY}/${ALICE}`), surveyDoc()));
  await assertSucceeds(setDoc(ref, surveyDoc()));
  await assertFails(setDoc(ref, surveyDoc()));
  await assertFails(updateDoc(ref, { participantId: "P02" }));
  await assertFails(deleteDoc(ref));
  await assertSucceeds(getDoc(ref));
  await assertFails(getDoc(doc(db(BOB), `${SURVEY}/${ALICE}`)));
});

test("アンケート: 形が違う回答・別の版は送れない", async () => {
  const ref = doc(db(ALICE), `${SURVEY}/${ALICE}`);
  await assertFails(setDoc(ref, surveyDoc({}, { sus3: 6 })));
  await assertFails(setDoc(ref, surveyDoc({}, { sus3: "4" })));
  await assertFails(setDoc(ref, surveyDoc({}, { gsn_exp: "expert" })));
  await assertFails(setDoc(ref, surveyDoc({}, { extra: 1 })));
  await assertFails(setDoc(ref, surveyDoc({}, { good: "x".repeat(2001) })));
  await assertFails(setDoc(ref, surveyDoc({ email: "a@example.com" })));
  await assertFails(setDoc(ref, surveyDoc({ participantId: "x".repeat(41) })));
  await assertFails(setDoc(ref, surveyDoc({ submittedAt: Timestamp.fromMillis(0) })));
  await assertFails(setDoc(doc(db(ALICE), `surveys/other/responses/${ALICE}`), surveyDoc()));
});

test("アンケート: 全員の回答を読めるのは admins に登録した研究者だけ", async () => {
  await assertSucceeds(setDoc(doc(db(ALICE), `${SURVEY}/${ALICE}`), surveyDoc()));
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), "admins/carol"), {});
  });
  await assertFails(getDocs(collection(db(BOB), SURVEY)));
  await assertFails(getDocs(collection(db(ALICE), SURVEY)));
  await assertFails(getDocs(collection(db("carol", false), SURVEY)));
  await assertSucceeds(getDocs(collection(db("carol"), SURVEY)));
  await assertSucceeds(getDoc(doc(db("carol"), "admins/carol")));
  await assertFails(getDoc(doc(db(BOB), "admins/carol")));
  await assertFails(setDoc(doc(db(BOB), `admins/${BOB}`), {}));
});
