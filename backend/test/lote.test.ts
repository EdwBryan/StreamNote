// Pruebas del procesamiento de un lote de SQS (backend/src/core/lote.ts).
// Correr con `npm test` desde backend/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { eachRecord } from '../src/core/lote.js';
import { HttpError } from '../src/core/http.js';

const lote = (n: number) => ({ Records: Array.from({ length: n }, (_, i) => ({ messageId: `m${i + 1}`, body: JSON.stringify({ n: i + 1 }) })) });
const callado = { error: () => {} };

test('procesa todos los mensajes y devuelve solo los que fallaron', async () => {
  const vistos: number[] = [];
  const r = await eachRecord(
    lote(3),
    async (m) => {
      vistos.push(m.n);
      if (m.n === 2) throw new Error('falló uno');
    },
    callado,
  );
  assert.deepEqual(vistos, [1, 2, 3]);
  assert.deepEqual(r, { batchItemFailures: [{ itemIdentifier: 'm2' }] });
});

test('si Aurora no despertó a tiempo, no intenta el resto del lote y lo devuelve entero a la cola', async () => {
  const vistos: number[] = [];
  const r = await eachRecord(
    lote(4),
    async (m) => {
      vistos.push(m.n);
      if (m.n === 2) throw new HttpError(503, 'La base de datos está despertando.', 'db_resuming');
    },
    callado,
  );
  assert.deepEqual(vistos, [1, 2]);
  assert.deepEqual(r, { batchItemFailures: [{ itemIdentifier: 'm2' }, { itemIdentifier: 'm3' }, { itemIdentifier: 'm4' }] });
});
