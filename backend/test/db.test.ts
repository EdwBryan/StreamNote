// Pruebas del reintento mientras Aurora despierta (backend/src/core/db.ts).
// Correr con `npm test` desde backend/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DataApiDb, mientrasDespierta } from '../src/core/db.js';
import { HttpError } from '../src/core/http.js';

/** Error con el mismo nombre que lanza el SDK de la Data API mientras Aurora despierta. */
function despertando(): Error {
  const e = new Error('The Aurora DB instance is resuming after being auto-paused. Please wait a few seconds and try again.');
  e.name = 'DatabaseResumingException';
  return e;
}

/** Reloj falso: dormir avanza el tiempo sin esperar de verdad. */
function relojFalso() {
  let ahora = 0;
  const esperas: number[] = [];
  return {
    esperas,
    ahora: () => ahora,
    dormir: async (ms: number) => {
      esperas.push(ms);
      ahora += ms;
    },
  };
}

test('si Aurora despierta a tiempo, repite la consulta y devuelve el resultado', async () => {
  const reloj = relojFalso();
  let llamadas = 0;
  const r = await mientrasDespierta(
    async () => {
      llamadas++;
      if (llamadas < 3) throw despertando();
      return 'filas';
    },
    reloj,
  );
  assert.equal(r, 'filas');
  assert.equal(llamadas, 3);
  assert.deepEqual(reloj.esperas, [2000, 2000]);
});

test('si no despierta en 10 s, responde 503 db_resuming sin pasarse del límite', async () => {
  const reloj = relojFalso();
  await assert.rejects(
    mientrasDespierta(async () => {
      throw despertando();
    }, reloj),
    (e: unknown) => e instanceof HttpError && e.status === 503 && e.code === 'db_resuming',
  );
  assert.ok(reloj.ahora() <= 10_000, `esperó ${reloj.ahora()} ms`);
  assert.deepEqual(reloj.esperas, [2000, 2000, 2000, 2000, 2000]);
});

test('cualquier otro error sube de inmediato, sin repetir la consulta', async () => {
  const reloj = relojFalso();
  let llamadas = 0;
  await assert.rejects(
    mientrasDespierta(async () => {
      llamadas++;
      throw new Error('syntax error at or near "SELEC"');
    }, reloj),
    /syntax error/,
  );
  assert.equal(llamadas, 1);
  assert.deepEqual(reloj.esperas, []);
});

test('DataApiDb.query reintenta la Data API mientras Aurora despierta', async () => {
  let llamadas = 0;
  const cliente = {
    send: async () => {
      llamadas++;
      if (llamadas === 1) throw despertando();
      return { formattedRecords: '[{"id":1}]' };
    },
  };
  const db = new DataApiDb(cliente as any, { resourceArn: 'arn', secretArn: 'arn', database: 'db' });
  assert.deepEqual(await db.query('SELECT 1 AS id'), [{ id: 1 }]);
  assert.equal(llamadas, 2);
});
