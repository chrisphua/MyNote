/** Minimal JOSE helpers built on WebCrypto — no npm dependency, no cold-start cost. */

/** The workers-types runtime does not ship the DOM's algorithm unions. */
type SubtleCryptoSignAlgorithm = string | { name: string; hash?: string };

export function b64uToBytes(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? '' : '='.repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64u(b: Uint8Array): string {
  let bin = '';
  for (const byte of b) bin += String.fromCharCode(byte);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64uJson(s: string): any {
  return JSON.parse(new TextDecoder().decode(b64uToBytes(s)));
}

/** Decode a JWS without verifying it. Only safe when TLS is the trust anchor. */
export function decodeJwsPayload<T = any>(jws: string): T {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new Error('malformed JWS');
  return b64uJson(parts[1]!) as T;
}

/** Sign a compact JWT with an ES256 (P-256) PKCS#8 key — used for Apple's API. */
export async function signEs256(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  pkcs8Pem: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(pkcs8Pem),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  return signWith(key, { name: 'ECDSA', hash: 'SHA-256' }, header, claims);
}

/** Sign a compact JWT with an RS256 PKCS#8 key — used for Google's API. */
export async function signRs256(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  pkcs8Pem: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(pkcs8Pem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return signWith(key, { name: 'RSASSA-PKCS1-v1_5' }, header, claims);
}

async function signWith(
  key: CryptoKey,
  algo: SubtleCryptoSignAlgorithm,
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
): Promise<string> {
  const enc = new TextEncoder();
  const h = bytesToB64u(enc.encode(JSON.stringify(header)));
  const p = bytesToB64u(enc.encode(JSON.stringify(claims)));
  const body = `${h}.${p}`;
  const sig = await crypto.subtle.sign(algo, key, enc.encode(body));
  return `${body}.${bytesToB64u(new Uint8Array(sig))}`;
}

export function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s+/g, '');
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

/**
 * The `appAccountToken` we attach to every StoreKit purchase.
 *
 * Apple requires a UUID, so one is derived deterministically from the Firebase
 * uid — both the app and the Worker can compute it with no extra round trip and
 * no stored mapping. It is what stops someone from claiming a transaction id
 * they did not pay for: the token in Apple's copy of the transaction must match
 * the caller.
 */
export async function appAccountToken(uid: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`mynote:${uid}`)),
  );
  const b = digest.slice(0, 16);
  b[6] = (b[6]! & 0x0f) | 0x50;   // version 5 (name-based)
  b[8] = (b[8]! & 0x3f) | 0x80;   // RFC 4122 variant
  const hex = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
