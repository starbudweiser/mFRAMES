// Vérifie le chiffrement du client navigateur (JavaScript pur) contre les implémentations de Node : SHA-256, HKDF, AES-256-GCM.
const nodeCrypto = require("crypto");
const C = require("../web/crypto.js");
let bad = 0;
const ok = (c, m) => { console.log((c ? "  OK  " : "  ÉCHEC  ") + m); if (!c) bad++; };
const eq = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)) === 0;

(async () => {
  for (const n of [0, 1, 55, 56, 64, 100, 1000]) {
    const d = nodeCrypto.randomBytes(n);
    ok(eq(C.sha256Sync(d), nodeCrypto.createHash("sha256").update(d).digest()), `SHA-256 sur ${n} octets`);
  }
  const secret = nodeCrypto.randomBytes(16), code = "482913";
  const mine = C._hkdf32(secret, Buffer.from("mFRAMES-session-v1"), Buffer.from(code));
  ok(eq(mine, Buffer.from(nodeCrypto.hkdfSync("sha256", secret, Buffer.from("mFRAMES-session-v1"), Buffer.from(code), 32))), "HKDF-SHA256 identique à Node");
  const key = mine;
  for (const n of [0, 1, 15, 16, 17, 100, 4096, 70000]) {
    const plain = nodeCrypto.randomBytes(n), nonce = nodeCrypto.randomBytes(12);
    const { ct, tag } = C._gcm(key, nonce, plain, false);
    const c = nodeCrypto.createCipheriv("aes-256-gcm", key, nonce); const ref = Buffer.concat([c.update(plain), c.final()]);
    ok(eq(ct, ref) && eq(tag, c.getAuthTag()), `AES-256-GCM (chiffrer) ${n} octets identique à Node`);
    const dc = nodeCrypto.createDecipheriv("aes-256-gcm", key, nonce); dc.setAuthTag(Buffer.from(tag));
    ok(eq(Buffer.concat([dc.update(ref), dc.final()]), plain), `AES-256-GCM : Node déchiffre ce que JS a chiffré (${n} octets)`);
    ok(eq(C._gcm(key, nonce, ref, true, c.getAuthTag()), plain), `AES-256-GCM (déchiffrer) ${n} octets`);
  }
  // balise fausse
  const nonce = nodeCrypto.randomBytes(12), { ct, tag } = C._gcm(key, nonce, Buffer.from("secret"), false);
  const t2 = Uint8Array.from(tag); t2[0] ^= 1;
  ok(C._gcm(key, nonce, ct, true, t2) === null, "une balise modifiée est refusée");
  // format de trame (nonce ‖ chiffré ‖ balise) : on déchiffre avec Node comme le fait CryptoKit
  const k = await C.deriveKey(secret, code);
  const sealed = await C.seal(k, Buffer.from("bonjour"));
  const d = nodeCrypto.createDecipheriv("aes-256-gcm", key, sealed.subarray(0, 12)); d.setAuthTag(Buffer.from(sealed.subarray(sealed.length - 16)));
  ok(Buffer.concat([d.update(sealed.subarray(12, sealed.length - 16)), d.final()]).toString() === "bonjour", "trame scellée au format nonce‖chiffré‖balise");
  ok(Buffer.from(await C.open(k, sealed)).toString() === "bonjour", "ouverture d'une trame");
  console.log(bad === 0 ? "TOUT PASSE" : `${bad} ÉCHEC(S)`);
  process.exit(bad === 0 ? 0 : 1);
})();
