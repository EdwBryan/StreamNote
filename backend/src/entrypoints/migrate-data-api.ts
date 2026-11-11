// Aplica las migraciones SQL pendientes en Aurora a través de la RDS Data API.
// Así el pipeline crea y actualiza las tablas por HTTPS con IAM, sin túnel ni acceso a la VPC.
//
//   DB_CLUSTER_ARN=... DB_SECRET_ARN=... npx tsx src/entrypoints/migrate-data-api.ts
//
// La Data API ejecuta una sentencia por llamada, así que cada archivo se parte en sentencias
// y todas se aplican dentro de una transacción: si una falla, el archivo entero se deshace.
import { readdir, readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  RDSDataClient,
  ExecuteStatementCommand,
  BeginTransactionCommand,
  CommitTransactionCommand,
  RollbackTransactionCommand,
} from '@aws-sdk/client-rds-data';

const resourceArn = process.env.DB_CLUSTER_ARN;
const secretArn = process.env.DB_SECRET_ARN;
const database = process.env.DB_NAME ?? 'streamnote';
if (!resourceArn || !secretArn) throw new Error('Faltan DB_CLUSTER_ARN y DB_SECRET_ARN');

const client = new RDSDataClient({ region: process.env.AWS_REGION ?? 'us-east-1' });
const dir = join(dirname(fileURLToPath(import.meta.url)), '../../migrations');
const base = { resourceArn, secretArn, database };

/** Quita comentarios "--" y parte en sentencias por ";" sin cortar dentro de textos entre comillas. */
export function splitStatements(sql: string): string[] {
  const out: string[] = [];
  let cur = '';
  let inQuote = false;
  for (let i = 0; i < sql.length; i++) {
    const ch = sql[i];
    if (!inQuote && ch === '-' && sql[i + 1] === '-') {
      while (i < sql.length && sql[i] !== '\n') i++;
      cur += '\n';
      continue;
    }
    if (ch === "'") inQuote = !inQuote;
    if (ch === ';' && !inQuote) {
      if (cur.trim()) out.push(cur.trim());
      cur = '';
      continue;
    }
    cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

/** Aurora escala a 0: la primera llamada puede encontrarla pausada mientras despierta. */
async function withResume<T>(fn: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (e: any) {
      const resuming = e?.name === 'DatabaseResumingException' || /resum/i.test(String(e?.message));
      if (!resuming || attempt >= 20) throw e;
      console.log(`Aurora está despertando, reintento ${attempt}...`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

const exec = (sql: string, transactionId?: string) =>
  withResume(() => client.send(new ExecuteStatementCommand({ ...base, sql, transactionId, formatRecordsAs: 'JSON' })));

await exec('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
const res = await exec('SELECT name FROM schema_migrations');
const done = new Set<string>(JSON.parse(res.formattedRecords ?? '[]').map((r: { name: string }) => r.name));

for (const file of (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort()) {
  if (done.has(file)) continue;
  const statements = splitStatements(await readFile(join(dir, file), 'utf8'));
  const { transactionId } = await withResume(() => client.send(new BeginTransactionCommand(base)));
  try {
    for (const stmt of statements) await exec(stmt, transactionId);
    await client.send(
      new ExecuteStatementCommand({
        ...base,
        transactionId,
        sql: 'INSERT INTO schema_migrations (name) VALUES (:name)',
        parameters: [{ name: 'name', value: { stringValue: file } }],
      }),
    );
    await client.send(new CommitTransactionCommand({ resourceArn, secretArn, transactionId }));
    console.log(`Migración aplicada: ${file} (${statements.length} sentencias)`);
  } catch (e) {
    await client.send(new RollbackTransactionCommand({ resourceArn, secretArn, transactionId }));
    throw e;
  }
}
console.log('Base de datos al día');
