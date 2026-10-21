// テスト用のパスキーの代役（navigator.credentials）。本物の認証器と同じく、
// PRF の値を「パスキーごとの秘密」と salt の HMAC-SHA256 で計算する。
// Node のテストと、ブラウザでの画面テスト（貼り付けて使う）の両方で使う。
export function installFakePasskeys(target = globalThis, { prf = true } = {}) {
  const subtle = globalThis.crypto.subtle;
  const creds = new Map(); // rawId(base64) -> 秘密の鍵
  const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
  async function prfOf(rawId, salt) {
    const key = creds.get(b64(rawId));
    return subtle.sign("HMAC", key, salt);
  }
  const fake = {
    calls: { create: 0, get: 0 },
    cancelNext: false,
    async create({ publicKey }) {
      fake.calls.create++;
      if (fake.cancelNext) { fake.cancelNext = false; throw Object.assign(new Error("cancelled"), { name: "NotAllowedError" }); }
      const rawId = globalThis.crypto.getRandomValues(new Uint8Array(16)).buffer;
      creds.set(b64(rawId), await subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, false, ["sign"]));
      // 多くの本物の認証器と同じく、作成時は enabled だけ返し、PRF の値は返さない
      return { rawId, getClientExtensionResults: () => ({ prf: { enabled: prf } }) };
    },
    async get({ publicKey }) {
      fake.calls.get++;
      if (fake.cancelNext) { fake.cancelNext = false; throw Object.assign(new Error("cancelled"), { name: "NotAllowedError" }); }
      // 登録済みのうち、許可リストにある最初のパスキーを使う
      const allowed = publicKey.allowCredentials.find((c) => creds.has(b64(c.id)));
      if (!allowed) throw Object.assign(new Error("no credential"), { name: "NotAllowedError" });
      const rawId = new Uint8Array(allowed.id).buffer;
      const idB64url = b64(rawId).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      const salt = publicKey.extensions.prf.evalByCredential[idB64url].first;
      const first = prf ? await prfOf(rawId, salt) : undefined;
      return { rawId, getClientExtensionResults: () => ({ prf: prf ? { results: { first } } : {} }) };
    },
  };
  target.PublicKeyCredential ??= function PublicKeyCredential() {};
  Object.defineProperty(target.navigator ?? (target.navigator = {}), "credentials",
    { value: fake, configurable: true });
  return fake;
}
