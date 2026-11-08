import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { GrupoFraude } from '../../models/fraude/grupo-fraude';
import { Hallazgo } from '../../models/fraude/hallazgo';

/** `motivo_movimiento.id_motivo_movimiento` para 'devolucion' -- fijo,
 * verificado contra el catalogo real (`SELECT * FROM motivo_movimiento`). */
const MOTIVO_DEVOLUCION = 3;

/**
 * Paso 3 (mitad reglas) del agrupador de casos de fraude: evalua las
 * reglas R-CASI (seccion 4 del documento original, `regla_casi_confirmado`
 * en Postgres) sobre un `GrupoFraude` ya armado. Cualquiera que cumpla sube
 * el caso a `casi_confirmado` sin importar el puntaje
 * (`PuntajeFraudeService` es independiente de esto).
 *
 * Todas piden lo mismo: que dos motores que no se hablan apunten a las mismas
 * cuentas (el grafo de resenas y las compras/registros por IP, por ejemplo).
 *
 * Se quitaron (2026-10-17, `plan pendiente/limpieza-fraude.md`): la rama
 * "comparten casa con calle" de R-CASI-1 (A.4 se descarto, nunca hubo
 * detector) y R-CASI-4 ("ciclo con dos olas"): las olas de B.4 no se guardan
 * en ninguna senal, asi que nunca se podia cumplir.
 */
@Injectable()
export class ReglasCasiConfirmadoService {
  private readonly logger = new Logger(ReglasCasiConfirmadoService.name);

  async evaluar(grupo: GrupoFraude): Promise<string[]> {
    const reglas: string[] = [];
    const tipos = new Set(grupo.hallazgos.map((hallazgo) => hallazgo.tipo));
    const nucleo = [...grupo.cuentas.entries()]
      .filter(([, esNucleo]) => esNucleo)
      .map(([cuenta]) => cuenta);

    if (
      (tipos.has('ciclo') ||
        tipos.has('reiterado') ||
        tipos.has('satelites')) &&
      (tipos.has('ip_multicuenta_compras') || tipos.has('granja_de_registros'))
    ) {
      reglas.push('R-CASI-1');
    }

    if (
      (tipos.has('ciclo') || tipos.has('mutuo')) &&
      this.contarReputacionExpresDelNucleo(grupo.hallazgos, nucleo) >= 2
    ) {
      reglas.push('R-CASI-2');
    }

    if (
      grupo.hallazgos.some(
        (hallazgo) =>
          hallazgo.fuente === 'grafo' || hallazgo.fuente === 'elastic',
      ) && // "el caso tiene otro hallazgo de resenas"
      (await this.tieneCompraYDevolucion(nucleo))
    ) {
      reglas.push('R-CASI-3');
    }

    if (
      tipos.has('coordinados') &&
      (tipos.has('ip_multicuenta_compras') || tipos.has('granja_de_registros'))
    ) {
      reglas.push('R-CASI-5');
    }

    return reglas;
  }

  /** Cuantos hallazgos de "reputacion expres" (autor con menos de 60
   * minutos de vida) tocan a alguna cuenta del nucleo -- simplificacion:
   * cuenta si CUALQUIER cuenta del hallazgo es nucleo, no distingue si
   * la del nucleo es quien escribio o quien recibio la resena (el
   * `Hallazgo` generico no separa autor de receptor). */
  private contarReputacionExpresDelNucleo(
    hallazgos: Hallazgo[],
    nucleo: number[],
  ): number {
    let contador = 0;
    for (const hallazgo of hallazgos) {
      if (hallazgo.tipo !== 'reputacion_expres') {
        continue;
      }
      const minutos = Number(hallazgo.metricas.autor_minutos_vida);
      if (!Number.isFinite(minutos) || minutos >= 60) {
        continue;
      }
      if (hallazgo.cuentas.some((cuenta) => nucleo.includes(cuenta))) {
        contador++;
      }
    }
    return contador;
  }

  /**
   * Una cuenta del nucleo califico un producto y despues lo devolvio: la
   * resena y la devolucion comparten autor (`resena.id_usuario` =
   * `pedido.id_usuario`), producto (`resena.id_producto_mongo` =
   * `oferta.id_producto_mongo`) y vendedor (`resena.id_usuario_vendedor` =
   * `oferta.id_usuario`). Cadena verificada contra el esquema real:
   * `resena -> pedido (por autor) -> stock_movimiento (motivo devolucion,
   * por pedido) -> oferta (por producto y vendedor)`.
   */
  private async tieneCompraYDevolucion(cuentas: number[]): Promise<boolean> {
    if (cuentas.length === 0) {
      return false;
    }
    try {
      const resultado = await pool.query<{ existe: boolean }>(
        `SELECT EXISTS (
           SELECT 1
             FROM resena r
             JOIN pedido p ON p.id_usuario = r.id_usuario
             JOIN stock_movimiento sm
               ON sm.id_pedido = p.id_pedido
              AND sm.id_motivo_movimiento = $2
              -- Solo lo que cancelo el mismo comprador: una cancelacion de la
              -- tienda (migracion 051) lleva al admin en id_usuario_modifico.
              AND sm.id_usuario_modifico = p.id_usuario
             JOIN oferta o
               ON o.id_oferta = sm.id_oferta
              AND o.id_usuario = r.id_usuario_vendedor
              AND o.id_producto_mongo = r.id_producto_mongo
            WHERE r.id_usuario = ANY($1::bigint[])
         ) AS existe`,
        [cuentas, MOTIVO_DEVOLUCION],
      );
      return resultado.rows[0].existe;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
