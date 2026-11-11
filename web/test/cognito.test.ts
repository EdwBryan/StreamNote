// Pruebas de las reglas puras del inicio de sesión con Cognito (web/src/cognito.ts).
// Correr con `npm test` desde web/ (Node 22.18 o superior: quita los tipos sin opciones).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { authorizeUrl, base64Url, challengeFor, cognito, readCallback } from '../src/cognito.ts';

const cfg = { domain: 'streamnote-dev-upao.auth.us-east-1.amazoncognito.com', clientId: 'abc123' };

test('sin variables de Cognito, la web usa el inicio de sesión de desarrollo', () => {
  assert.equal(cognito, null);
});

test('base64Url no deja +, / ni relleno', () => {
  assert.equal(base64Url(new Uint8Array([251, 255, 254])), '-__-');
  assert.equal(base64Url(new Uint8Array([1])), 'AQ');
});

test('el reto de PKCE coincide con el ejemplo del estándar (RFC 7636, apéndice B)', async () => {
  assert.equal(await challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
});

test('la dirección de entrada pide un código con PKCE y vuelve a la web', () => {
  const url = new URL(authorizeUrl(cfg, { kind: 'login', redirectUri: 'https://d111.cloudfront.net', state: 'st', challenge: 'ch' }));
  assert.equal(url.origin + url.pathname, 'https://streamnote-dev-upao.auth.us-east-1.amazoncognito.com/oauth2/authorize');
  assert.deepEqual(Object.fromEntries(url.searchParams), {
    response_type: 'code',
    client_id: 'abc123',
    redirect_uri: 'https://d111.cloudfront.net',
    scope: 'openid email profile',
    state: 'st',
    code_challenge: 'ch',
    code_challenge_method: 'S256',
  });
});

test('crear una cuenta usa la página de registro con los mismos datos', () => {
  const url = new URL(authorizeUrl(cfg, { kind: 'signup', redirectUri: 'https://d111.cloudfront.net', state: 'st', challenge: 'ch' }));
  assert.equal(url.pathname, '/signup');
  assert.equal(url.searchParams.get('code_challenge'), 'ch');
});

test('la vuelta de Cognito entrega el código solo si el state es el enviado', () => {
  assert.equal(readCallback('?code=c1&state=st', 'st'), 'c1');
  assert.equal(readCallback('', 'st'), null);
  assert.throws(() => readCallback('?code=c1&state=otro', 'st'), /no se inició en esta pestaña/);
  assert.throws(() => readCallback('?code=c1&state=st', null), /no se inició en esta pestaña/);
});

test('un error de Cognito se muestra con su descripción', () => {
  assert.throws(() => readCallback('?error=access_denied&error_description=Usuario+no+confirmado', 'st'), /Usuario no confirmado/);
});
