// mFRAMES — chiffrement du client navigateur : SHA-256, HKDF, AES-256-GCM (compatibles avec CryptoKit côté app).
// WebCrypto quand le contexte est sécurisé (https, localhost) ; sinon implémentation JavaScript (une page http sur le réseau local n'a pas `crypto.subtle`).
(function (root) {
  "use strict";
  const enc = new TextEncoder();

  // ---- SHA-256 ----
  const K = new Uint32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
  function sha256(data) {
    const h = new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);
    const n = data.length, padded = new Uint8Array(((n + 9 + 63) >> 6) << 6);
    padded.set(data); padded[n] = 0x80;
    const dv = new DataView(padded.buffer);
    dv.setUint32(padded.length - 8, Math.floor(n / 0x20000000), false); dv.setUint32(padded.length - 4, (n << 3) >>> 0, false);
    const w = new Uint32Array(64);
    for (let o = 0; o < padded.length; o += 64) {
      for (let i = 0; i < 16; i++) w[i] = dv.getUint32(o + i * 4, false);
      for (let i = 16; i < 64; i++) {
        const a = w[i - 15], b = w[i - 2];
        const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3), s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let [a, b, c, d, e, f, g, hh] = h;
      for (let i = 0; i < 64; i++) {
        const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7)), ch = (e & f) ^ (~e & g);
        const t1 = (hh + S1 + ch + K[i] + w[i]) | 0;
        const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10)), mj = (a & b) ^ (a & c) ^ (b & c);
        const t2 = (S0 + mj) | 0;
        hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    const out = new Uint8Array(32), odv = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) odv.setUint32(i * 4, h[i], false);
    return out;
  }
  function hmac(key, msg) {
    if (key.length > 64) key = sha256(key);
    const k = new Uint8Array(64); k.set(key);
    const ip = new Uint8Array(64 + msg.length), op = new Uint8Array(96);
    for (let i = 0; i < 64; i++) { ip[i] = k[i] ^ 0x36; op[i] = k[i] ^ 0x5c; }
    ip.set(msg, 64); op.set(sha256(ip), 64);
    return sha256(op);
  }
  function hkdf32(ikm, salt, info) {            // RFC 5869, une seule sortie de 32 octets
    const prk = hmac(salt, ikm);
    const m = new Uint8Array(info.length + 1); m.set(info); m[info.length] = 1;
    return hmac(prk, m);
  }

  // ---- AES-256 (tables) + GCM ----
  const SBOX = new Uint8Array(256), Te = [new Uint32Array(256), new Uint32Array(256), new Uint32Array(256), new Uint32Array(256)];
  (function () {
    let p = 1, q = 1;
    do { p = p ^ ((p << 1) & 0xff) ^ (p & 0x80 ? 0x1b : 0); q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff; if (q & 0x80) q ^= 0x09; 
         const x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4)); SBOX[p] = (x ^ 0x63) & 0xff; } while (p !== 1);
    SBOX[0] = 0x63;
    for (let i = 0; i < 256; i++) {
      const s = SBOX[i], s2 = ((s << 1) ^ (s & 0x80 ? 0x11b : 0)) & 0xff, s3 = s2 ^ s;
      const t = ((s2 << 24) | (s << 16) | (s << 8) | s3) >>> 0;
      Te[0][i] = t; Te[1][i] = ((t >>> 8) | (t << 24)) >>> 0; Te[2][i] = ((t >>> 16) | (t << 16)) >>> 0; Te[3][i] = ((t >>> 24) | (t << 8)) >>> 0;
    }
  })();
  function expandKey(key) {
    const nk = 8, rounds = 14, w = new Uint32Array(4 * (rounds + 1));
    for (let i = 0; i < nk; i++) w[i] = ((key[4*i] << 24) | (key[4*i+1] << 16) | (key[4*i+2] << 8) | key[4*i+3]) >>> 0;
    let rcon = 1;
    for (let i = nk; i < w.length; i++) {
      let t = w[i - 1];
      if (i % nk === 0) { t = ((SBOX[(t >>> 16) & 255] << 24) | (SBOX[(t >>> 8) & 255] << 16) | (SBOX[t & 255] << 8) | SBOX[t >>> 24]) ^ (rcon << 24); rcon = (rcon << 1) ^ (rcon & 0x80 ? 0x11b : 0); }
      else if (i % nk === 4) t = (SBOX[t >>> 24] << 24) | (SBOX[(t >>> 16) & 255] << 16) | (SBOX[(t >>> 8) & 255] << 8) | SBOX[t & 255];
      w[i] = (w[i - nk] ^ t) >>> 0;
    }
    return w;
  }
  function encryptBlock(w, s0, s1, s2, s3, out) {
    s0 ^= w[0]; s1 ^= w[1]; s2 ^= w[2]; s3 ^= w[3];
    for (let r = 1; r < 14; r++) {
      const t0 = Te[0][s0 >>> 24] ^ Te[1][(s1 >>> 16) & 255] ^ Te[2][(s2 >>> 8) & 255] ^ Te[3][s3 & 255] ^ w[4*r];
      const t1 = Te[0][s1 >>> 24] ^ Te[1][(s2 >>> 16) & 255] ^ Te[2][(s3 >>> 8) & 255] ^ Te[3][s0 & 255] ^ w[4*r+1];
      const t2 = Te[0][s2 >>> 24] ^ Te[1][(s3 >>> 16) & 255] ^ Te[2][(s0 >>> 8) & 255] ^ Te[3][s1 & 255] ^ w[4*r+2];
      const t3 = Te[0][s3 >>> 24] ^ Te[1][(s0 >>> 16) & 255] ^ Te[2][(s1 >>> 8) & 255] ^ Te[3][s2 & 255] ^ w[4*r+3];
      s0 = t0; s1 = t1; s2 = t2; s3 = t3;
    }
    out[0] = (((SBOX[s0 >>> 24] << 24) | (SBOX[(s1 >>> 16) & 255] << 16) | (SBOX[(s2 >>> 8) & 255] << 8) | SBOX[s3 & 255]) ^ w[56]) >>> 0;
    out[1] = (((SBOX[s1 >>> 24] << 24) | (SBOX[(s2 >>> 16) & 255] << 16) | (SBOX[(s3 >>> 8) & 255] << 8) | SBOX[s0 & 255]) ^ w[57]) >>> 0;
    out[2] = (((SBOX[s2 >>> 24] << 24) | (SBOX[(s3 >>> 16) & 255] << 16) | (SBOX[(s0 >>> 8) & 255] << 8) | SBOX[s1 & 255]) ^ w[58]) >>> 0;
    out[3] = (((SBOX[s3 >>> 24] << 24) | (SBOX[(s0 >>> 16) & 255] << 16) | (SBOX[(s1 >>> 8) & 255] << 8) | SBOX[s2 & 255]) ^ w[59]) >>> 0;
  }
  const be32 = (b, o) => ((b[o] << 24) | (b[o+1] << 16) | (b[o+2] << 8) | b[o+3]) >>> 0;
  const put32 = (b, o, v) => { b[o] = v >>> 24; b[o+1] = (v >>> 16) & 255; b[o+2] = (v >>> 8) & 255; b[o+3] = v & 255; };

  function ghashMul(x, h) {                       // x ← x · h dans GF(2^128), mots de 32 bits (gros-boutiste)
    let z0 = 0, z1 = 0, z2 = 0, z3 = 0, v0 = h[0], v1 = h[1], v2 = h[2], v3 = h[3];
    for (let i = 0; i < 128; i++) {
      const bit = (x[i >> 5] >>> (31 - (i & 31))) & 1;
      if (bit) { z0 ^= v0; z1 ^= v1; z2 ^= v2; z3 ^= v3; }
      const lsb = v3 & 1;
      v3 = ((v3 >>> 1) | (v2 << 31)) >>> 0; v2 = ((v2 >>> 1) | (v1 << 31)) >>> 0; v1 = ((v1 >>> 1) | (v0 << 31)) >>> 0; v0 = v0 >>> 1;
      if (lsb) v0 = (v0 ^ 0xe1000000) >>> 0;
    }
    x[0] = z0 >>> 0; x[1] = z1 >>> 0; x[2] = z2 >>> 0; x[3] = z3 >>> 0;
  }
  function gcm(keyBytes, nonce, data, decrypt, expectedTag) {   // data : texte clair (chiffrer) ou chiffré sans la balise (déchiffrer)
    const w = expandKey(keyBytes), tmp = new Uint32Array(4);
    encryptBlock(w, 0, 0, 0, 0, tmp);
    const H = new Uint32Array(tmp);
    const j0 = [be32(nonce, 0), be32(nonce, 4), be32(nonce, 8), 1];
    const out = new Uint8Array(data.length), y = new Uint32Array(4), blk = new Uint32Array(4);
    let ctr = 2;
    for (let o = 0; o < data.length; o += 16) {
      encryptBlock(w, j0[0], j0[1], j0[2], ctr++ >>> 0, tmp);
      const n = Math.min(16, data.length - o), ks = new Uint8Array(16);
      for (let i = 0; i < 4; i++) put32(ks, i * 4, tmp[i]);
      for (let i = 0; i < n; i++) out[o + i] = data[o + i] ^ ks[i];
      const ct = decrypt ? data : out, cb = new Uint8Array(16); cb.set(ct.subarray(o, o + n));
      for (let i = 0; i < 4; i++) blk[i] = be32(cb, i * 4);
      y[0] ^= blk[0]; y[1] ^= blk[1]; y[2] ^= blk[2]; y[3] ^= blk[3];
      ghashMul(y, H);
    }
    y[0] ^= 0; y[1] ^= 0; y[2] ^= Math.floor(data.length / 0x20000000); y[3] ^= (data.length << 3) >>> 0;   // longueurs (AAD = 0, texte = n bits)
    ghashMul(y, H);
    encryptBlock(w, j0[0], j0[1], j0[2], 1, tmp);
    const tag = new Uint8Array(16);
    for (let i = 0; i < 4; i++) put32(tag, i * 4, (y[i] ^ tmp[i]) >>> 0);
    if (decrypt) { let d = 0; for (let i = 0; i < 16; i++) d |= tag[i] ^ expectedTag[i]; return d === 0 ? out : null; }
    return { ct: out, tag };
  }

  const subtle = root.crypto && root.crypto.subtle;
  const api = {
    usingWebCrypto: !!subtle,
    sha256: async (data) => subtle ? new Uint8Array(await subtle.digest("SHA-256", data)) : sha256(data),
    sha256Sync: sha256,
    // Clé de session : HKDF-SHA256(secret, sel « mFRAMES-session-v1 », info = code).
    deriveKey: async (secret, code) => {
      const salt = enc.encode("mFRAMES-session-v1"), info = enc.encode(code);
      const raw = hkdf32(secret, salt, info);
      if (!subtle) return { raw };
      return { raw, key: await subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]) };
    },
    // Trame scellée au format CryptoKit : nonce (12) ‖ chiffré ‖ balise (16).
    seal: async (k, plain) => {
      const nonce = root.crypto.getRandomValues(new Uint8Array(12));
      let ct, tag;
      if (k.key) { const r = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce }, k.key, plain)); ct = r.subarray(0, r.length - 16); tag = r.subarray(r.length - 16); }
      else ({ ct, tag } = gcm(k.raw, nonce, plain, false));
      const out = new Uint8Array(12 + ct.length + 16); out.set(nonce); out.set(ct, 12); out.set(tag, 12 + ct.length);
      return out;
    },
    open: async (k, sealed) => {
      if (sealed.length < 28) return null;
      const nonce = sealed.subarray(0, 12), body = sealed.subarray(12);
      try {
        if (k.key) return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: nonce }, k.key, body));
        return gcm(k.raw, nonce, body.subarray(0, body.length - 16), true, body.subarray(body.length - 16));
      } catch (e) { return null; }
    },
    _gcm: gcm, _hkdf32: hkdf32,
  };
  root.MFCrypto = api;
  if (typeof module !== "undefined") module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
