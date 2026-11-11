// Inicio de sesión con Amazon Cognito: página alojada por Cognito y flujo de código con PKCE.
// La web nunca ve la contraseña: Cognito la pide en su página y devuelve un código de un solo
// uso, que aquí se canjea por el token de identidad (ID token) que el backend sabe validar.

export interface CognitoConfig {
  /** Dominio de la página de Cognito, sin https:// */
  domain: string;
  /** ID público del cliente web en el pool */
  clientId: string;
}

// Valores públicos que el pipeline pasa al compilar (.github/workflows/deploy.yml)
const env = (import.meta as { env?: Record<string, string | undefined> }).env ?? {};

/** Configuración de Cognito, o null cuando la web usa el inicio de sesión de desarrollo. */
export const cognito: CognitoConfig | null =
  env.VITE_AUTH_MODE === 'cognito' && env.VITE_COGNITO_DOMAIN && env.VITE_COGNITO_CLIENT_ID
    ? { domain: env.VITE_COGNITO_DOMAIN, clientId: env.VITE_COGNITO_CLIENT_ID }
    : null;

const STORAGE_KEY = 'streamnote.cognito';

// ---------- Reglas puras (con pruebas en web/test/cognito.test.ts) ----------

/** Base64 apto para URL: sin +, / ni relleno. */
export function base64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Texto aleatorio para el verificador de PKCE y para `state`. */
export function randomText(): string {
  return base64Url(crypto.getRandomValues(new Uint8Array(32)));
}

/** Reto de PKCE: SHA-256 del verificador. Cognito lo compara al canjear el código. */
export async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return base64Url(new Uint8Array(digest));
}

/** Dirección de la página de Cognito para entrar (`login`) o crear una cuenta (`signup`). */
export function authorizeUrl(
  cfg: CognitoConfig,
  o: { kind: 'login' | 'signup'; redirectUri: string; state: string; challenge: string },
): string {
  const query = new URLSearchParams({
    response_type: 'code',
    client_id: cfg.clientId,
    redirect_uri: o.redirectUri,
    scope: 'openid email profile',
    state: o.state,
    code_challenge: o.challenge,
    code_challenge_method: 'S256',
  });
  return `https://${cfg.domain}/${o.kind === 'signup' ? 'signup' : 'oauth2/authorize'}?${query}`;
}

/**
 * Lee la vuelta desde Cognito (`?code=…&state=…`).
 * Devuelve el código, o null si la página no viene de Cognito. Lanza un error si Cognito
 * devolvió uno o si `state` no es el que esta pestaña envió (la respuesta no es para nosotros).
 */
export function readCallback(search: string, expectedState: string | null): string | null {
  const query = new URLSearchParams(search);
  const failure = query.get('error_description') ?? query.get('error');
  if (failure) throw new Error(`Cognito no permitió entrar: ${failure}`);
  const code = query.get('code');
  if (!code) return null;
  if (!expectedState || query.get('state') !== expectedState) {
    throw new Error('El inicio de sesión no se inició en esta pestaña. Vuelve a intentarlo.');
  }
  return code;
}

// ---------- Navegador ----------

/** Lleva a la página de Cognito. Guarda el verificador en esta pestaña para la vuelta. */
export async function startLogin(kind: 'login' | 'signup'): Promise<void> {
  if (!cognito) return;
  const verifier = randomText();
  const state = randomText();
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ verifier, state }));
  window.location.assign(
    authorizeUrl(cognito, { kind, redirectUri: window.location.origin, state, challenge: await challengeFor(verifier) }),
  );
}

let pending: Promise<string | null> | undefined;

/**
 * Si la página viene de Cognito, canjea el código por el ID token y lo devuelve.
 * Devuelve null si no hay nada que canjear. El código sirve una sola vez, así que las
 * llamadas simultáneas (React monta dos veces en desarrollo) comparten el mismo canje.
 * Al terminar se olvida: una llamada posterior no vuelve a entregar un token ya usado.
 */
export function finishLogin(): Promise<string | null> {
  return (pending ??= exchange().finally(() => {
    pending = undefined;
  }));
}

async function exchange(): Promise<string | null> {
  if (!cognito) return null;
  const saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? 'null') as { verifier: string; state: string } | null;
  let code: string | null;
  try {
    code = readCallback(window.location.search, saved?.state ?? null);
  } finally {
    // El código y el verificador ya no deben quedar ni en la barra de direcciones ni guardados
    if (window.location.search) window.history.replaceState(null, '', window.location.pathname);
    sessionStorage.removeItem(STORAGE_KEY);
  }
  if (!code || !saved) return null;

  const res = await fetch(`https://${cognito.domain}/oauth2/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: cognito.clientId,
      code,
      redirect_uri: window.location.origin,
      code_verifier: saved.verifier,
    }),
  });
  const data = (await res.json().catch(() => null)) as { id_token?: string; error?: string } | null;
  if (!res.ok || !data?.id_token) {
    throw new Error(`Cognito no entregó la sesión${data?.error ? ` (${data.error})` : ''}. Vuelve a intentarlo.`);
  }
  return data.id_token;
}

/** Cierra también la sesión en Cognito; sin esto, «Entrar» volvería a entrar sin pedir contraseña. */
export function logout(): void {
  if (!cognito) return;
  const query = new URLSearchParams({ client_id: cognito.clientId, logout_uri: window.location.origin });
  window.location.assign(`https://${cognito.domain}/logout?${query}`);
}
