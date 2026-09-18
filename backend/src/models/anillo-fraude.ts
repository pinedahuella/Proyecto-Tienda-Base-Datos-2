import { EstadoAlertaFraude } from './alerta-fraude';

/**
 * Catalogo de `tipo_anillo_fraude` (ver
 * `elementos Generales/plan pendiente/anillos-fraude-persistencia.sql`).
 *
 * El orden del INSERT fija los ids -- mismo criterio que
 * `ID_TIPO_ALERTA_FRAUDE_*` en `models/alerta-fraude.ts`: un catalogo tan
 * chico no cambia sin una migracion nueva, asi que es seguro fijarlos aqui
 * en vez de consultarlos cada vez.
 */
export const ID_TIPO_ANILLO_FRAUDE_MUTUO = 1;
export const ID_TIPO_ANILLO_FRAUDE_CICLO = 2;
export const ID_TIPO_ANILLO_FRAUDE_REITERADO = 3;

export type TipoAnilloFraude = 'mutuo' | 'ciclo' | 'reiterado';

/**
 * Una cuenta del anillo, derivada -- NO hay tabla `anillo_fraude_cuenta`:
 * para `mutuo`/`ciclo`/`reiterado` toda cuenta del anillo es autor o
 * vendedor de alguna de sus resenas, asi que sale de un join contra
 * `resena.id_usuario`/`id_usuario_vendedor` (ver
 * `FraudeAnillosPersistidosService`).
 */
export interface CuentaDeAnillo {
  id_usuario: string;
  usuario: string;
}

/** `GET /admin/fraude/alertas-resenas`: un anillo, forma de API. */
export interface AnilloFraude {
  id_anillo_fraude: string;
  tipo: TipoAnilloFraude;
  clave: string;
  cuentas: CuentaDeAnillo[];
  resenas: number[];
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  ultima_vez_confirmado_activo: Date;
  fecha_actualizacion: Date;
}

/** Una resena, tal como vive en el grafo -- fila de `DetalleAnilloGrafo.resenas`. */
export interface ResenaDeAnilloGrafo {
  id_resena: number;
  autor: string | null;
  correo_autor: string | null;
  vendedor: string | null;
  correo_vendedor: string | null;
  producto: string | null;
  calificacion: number;
  fecha: string;
}

/**
 * `GET /admin/fraude/alertas-resenas/:id/detalle-grafo`: el detalle REAL
 * de un anillo ya persistido, consultado en vivo contra Neo4j a partir de
 * los ids de `anillo_fraude_resena` -- no vuelve a correr A.1/A.2, solo pide
 * las resenas puntuales que ya se sabe que son la evidencia de este anillo.
 */
export interface DetalleAnilloGrafo {
  id_anillo_fraude: string;
  tipo: TipoAnilloFraude;
  clave: string;
  resenas: ResenaDeAnilloGrafo[];
}
