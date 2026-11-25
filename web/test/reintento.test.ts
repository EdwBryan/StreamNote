// Pruebas de cuándo la web vuelve a intentar sola (web/src/reintento.ts).
// Correr con `npm test` desde web/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { esperaAntesDeReintentar } from '../src/reintento.ts';

const despertando = { error: 'db_resuming', message: 'La base de datos está despertando.' };

test('503 db_resuming: espera 3, 5 y 8 segundos en los tres primeros intentos', () => {
  assert.equal(esperaAntesDeReintentar(503, despertando, 0), 3000);
  assert.equal(esperaAntesDeReintentar(503, despertando, 1), 5000);
  assert.equal(esperaAntesDeReintentar(503, despertando, 2), 8000);
});

test('503 db_resuming en el intento 3: ya no reintenta', () => {
  assert.equal(esperaAntesDeReintentar(503, despertando, 3), null);
});

test('500: no reintenta', () => {
  assert.equal(esperaAntesDeReintentar(500, { error: 'internal' }, 0), null);
});

test('503 sin db_resuming: no reintenta, porque no sabemos si la consulta se ejecutó', () => {
  assert.equal(esperaAntesDeReintentar(503, { error: 'otro' }, 0), null);
  assert.equal(esperaAntesDeReintentar(503, null, 0), null);
});

test('db_resuming con otro código de estado: no reintenta', () => {
  assert.equal(esperaAntesDeReintentar(500, despertando, 0), null);
});
