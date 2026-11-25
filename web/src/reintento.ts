// Cuándo la web vuelve a intentar sola una petición a la API.
// Solo cuando el backend responde 503 «db_resuming»: Aurora estaba pausada y la consulta
// no llegó a ejecutarse, así que repetirla es seguro. Cualquier otro error se muestra tal cual.

/** Esperas antes de cada reintento: tras 3, 5 y 8 segundos (Aurora tarda menos de 15 s en despertar). */
const ESPERAS_MS = [3_000, 5_000, 8_000];

/** Cuánto esperar antes de reintentar, o null si no hay que reintentar. */
export function esperaAntesDeReintentar(status: number, cuerpo: any, intento: number): number | null {
  if (status !== 503 || cuerpo?.error !== 'db_resuming') return null;
  return ESPERAS_MS[intento] ?? null;
}
