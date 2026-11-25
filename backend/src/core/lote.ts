// Procesa un lote de SQS mensaje por mensaje (ReportBatchItemFailures): los que fallan vuelven a la cola.
import { HttpError } from './http.js';

export interface SqsEvent {
  Records: { messageId: string; body: string; eventSourceARN?: string }[];
}

export async function eachRecord(event: SqsEvent, fn: (body: any) => Promise<unknown>, log: Pick<Console, 'error'> = console) {
  const batchItemFailures: { itemIdentifier: string }[] = [];
  for (const [i, r] of event.Records.entries()) {
    try {
      await fn(JSON.parse(r.body));
    } catch (e) {
      log.error(e);
      batchItemFailures.push({ itemIdentifier: r.messageId });
      // Si Aurora no despertó a tiempo, los demás mensajes esperarían lo mismo y la Lambda se quedaría
      // sin tiempo a mitad del lote. Mejor devolverlos todos a la cola: vuelven cuando ya está despierta.
      if (e instanceof HttpError && e.code === 'db_resuming') {
        for (const resto of event.Records.slice(i + 1)) batchItemFailures.push({ itemIdentifier: resto.messageId });
        break;
      }
    }
  }
  return { batchItemFailures };
}
