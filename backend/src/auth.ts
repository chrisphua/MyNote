import { HttpError } from './types';
import type { Env } from './types';
import { b64uJson, b64uToBytes } from './jwt';

const JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

export interface AuthedUser {
  uid: string;
  email: string | null;
  name: string | null;
}

interface Jwk { kid: string; n: string; e: string; kty: string; alg: string }

let jwksCache: { keys: Map<string, CryptoKey>; expiresAt: number } | null = null;

async function getSigningKey(kid: string): Promise<CryptoKey> {
  const now = Date.now();
  if (jwksCache && jwksCache.expiresAt > now) {
    const hit = jwksCache.keys.get(kid);
    if (hit) return hit;
  }

  const res = await fetch(JWKS_URL);
  if (!res.ok) throw new HttpError(503, 'could not fetch Google signing keys', 'jwks_unavailable');

  // Google rotates these roughly daily and tells us how long they are good for.
  const cc = res.headers.get('cache-control') ?? '';
  const maxAge = Number(/max-age=(\d+)/.exec(cc)?.[1] ?? 3600);
  const body = (await res.json()) as { keys: Jwk[] };

  const keys = new Map<string, CryptoKey>();
  for (const jwk of body.keys) {
    if (jwk.kty !== 'RSA') continue;
    keys.set(
      jwk.kid,
      await crypto.subtle.importKey(
        'jwk',
        { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify'],
      ),
    );
  }
  jwksCache = { keys, expiresAt: now + maxAge * 1000 };

  const key = keys.get(kid);
  if (!key) throw new HttpError(401, 'unknown token key id', 'bad_token');
  return key;
}

/**
 * Verify a Firebase ID token.
 *
 * Firebase Auth is doing the expensive part (Google/Apple/email sign-in, password
 * resets, account recovery) for free; all we do here is check the signature and
 * claims so we can trust `sub` as our user id.
 */
export async function verifyFirebaseToken(token: string, env: Env): Promise<AuthedUser> {
  const parts = token.split('.');
  if (parts.length !== 3) throw new HttpError(401, 'malformed token', 'bad_token');
  const [rawHeader, rawPayload, rawSig] = parts as [string, string, string];

  let header: any, payload: any;
  try {
    header = b64uJson(rawHeader);
    payload = b64uJson(rawPayload);
  } catch {
    throw new HttpError(401, 'malformed token', 'bad_token');
  }

  if (header.alg !== 'RS256') throw new HttpError(401, 'unexpected token algorithm', 'bad_token');
  if (typeof header.kid !== 'string') throw new HttpError(401, 'token missing key id', 'bad_token');

  const key = await getSigningKey(header.kid);
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    b64uToBytes(rawSig),
    new TextEncoder().encode(`${rawHeader}.${rawPayload}`),
  );
  if (!ok) throw new HttpError(401, 'bad token signature', 'bad_token');

  const now = Math.floor(Date.now() / 1000);
  const project = env.FIREBASE_PROJECT_ID;
  if (payload.aud !== project) throw new HttpError(401, 'token audience mismatch', 'bad_token');
  if (payload.iss !== `https://securetoken.google.com/${project}`) {
    throw new HttpError(401, 'token issuer mismatch', 'bad_token');
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new HttpError(401, 'token missing subject', 'bad_token');
  }
  if (typeof payload.exp !== 'number' || payload.exp <= now) {
    throw new HttpError(401, 'token expired', 'token_expired');
  }
  if (typeof payload.iat !== 'number' || payload.iat > now + 300) {
    throw new HttpError(401, 'token issued in the future', 'bad_token');
  }

  return {
    uid: payload.sub,
    email: typeof payload.email === 'string' ? payload.email : null,
    name: typeof payload.name === 'string' ? payload.name : null,
  };
}

export async function requireUser(req: Request, env: Env): Promise<AuthedUser> {
  const header = req.headers.get('authorization') ?? '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match) throw new HttpError(401, 'missing bearer token', 'unauthenticated');
  return verifyFirebaseToken(match[1]!, env);
}
