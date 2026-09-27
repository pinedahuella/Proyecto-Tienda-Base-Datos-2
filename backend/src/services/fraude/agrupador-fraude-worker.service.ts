import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { HallazgoFraudeAdaptadorService } from './hallazgo-fraude-adaptador.service';
import { AgrupadorFraudeService } from './agrupador-fraude.service';
import { PersistenciaCasoFraudeService } from './persistencia-caso-fraude.service';

/**
 * Paso 6 del agrupador de casos de fraude: cuando corre.
 *
 * El documento original (seccion 6) propone "despues de cada deteccion,
 * solo sobre los casos tocados" -- enganchado a cada uno de los
 * detectores existentes (`AnillosDetectorService`,
 * `PatronesFraudeDetectorService`, `HallazgosEventoFraudeDetectorService`,
 * y los servicios de fraude de login). Se decidio algo mas simple: un
 * worker PROPIO con `@Interval`, que recalcula TODO desde cero cada vez
 * -- consistente con `PersistenciaCasoFraudeService`, que ya asume que
 * `grupo` trae el universo completo vigente, no un delta. Evita tocar
 * cuatro servicios ya existentes solo para agregarles una llamada al
 * final. El costo: una deteccion nueva tarda hasta `INTERVALO_MS` en
 * reflejarse en un caso, en vez de ser instantanea.
 *
 * Mismo patron `@Interval` + bandera `procesando` que el resto de los
 * workers del proyecto: nunca lanza, un fallo se loguea y se reintenta en
 * la proxima corrida.
 *
 * Al final de cada corrida completa llama tambien a
 * `PersistenciaCasoFraudeService.limpiarCasosVaciosPendientes()`
 * (`docs/BACKEND-PENDIENTE.md`, item C8) -- ver el comentario de ese
 * metodo para el porque.
 *
 * **Corre tambien al arrancar el backend (agregado 2026-09-27, item C7).**
 * El `@Interval` de Nest NO dispara de inmediato, solo despues de que pase
 * el primer `INTERVALO_MS` (15 min) -- en una demo, eso significaba
 * esperar 15 minutos despues de levantar el backend para ver la pestana
 * de Casos con algo. `onApplicationBootstrap()` llama a la misma
 * `ejecutarCiclo()` una vez, apenas Nest termina de inicializar todos los
 * modulos -- mismo patron que `MasVendidosSyncService`/
 * `RegistroOfertasSyncService`/`DisparadorReglasPeriodoService`.
 */
@Injectable()
export class AgrupadorFraudeWorkerService implements OnApplicationBootstrap {
  private readonly logger = new Logger(AgrupadorFraudeWorkerService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  private procesando = false;

  constructor(
    private readonly adaptador: HallazgoFraudeAdaptadorService,
    private readonly agrupador: AgrupadorFraudeService,
    private readonly persistencia: PersistenciaCasoFraudeService,
  ) {}

  @Interval('agrupador-fraude', AgrupadorFraudeWorkerService.INTERVALO_MS)
  async ejecutar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      await this.ejecutarCiclo();
    } finally {
      this.procesando = false;
    }
  }

  /** Ver el comentario de la clase -- corre una vez, al arrancar. */
  async onApplicationBootstrap(): Promise<void> {
    await this.ejecutar();
  }

  private async ejecutarCiclo(): Promise<void> {
    let hallazgos;
    try {
      const [grafo, eventos, login] = await Promise.all([
        this.adaptador.obtenerDeGrafo(),
        this.adaptador.obtenerDeEventos(),
        this.adaptador.obtenerDeLogin(),
      ]);
      hallazgos = [...grafo, ...eventos, ...login];
    } catch (error) {
      this.logger.warn(
        `agrupador de fraude: no se pudo leer los hallazgos (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    if (hallazgos.length === 0) {
      return;
    }

    const grupos = await this.agrupador.agrupar(hallazgos);
    let persistidos = 0;
    for (const grupo of grupos) {
      try {
        await this.persistencia.persistir(grupo);
        persistidos++;
      } catch (error) {
        this.logger.warn(
          `agrupador de fraude: no se pudo persistir un grupo (${(error as Error)?.message ?? error})`,
        );
      }
    }

    this.logger.log(
      `agrupador de fraude: ${persistidos}/${grupos.length} caso(s) al dia, de ${hallazgos.length} hallazgo(s)`,
    );

    // Al final de la corrida completa, nunca por-grupo (ver el comentario
    // del metodo): un grupo puede dejar vacio un caso que otro grupo de
    // esta misma corrida ya toco.
    try {
      const borrados = await this.persistencia.limpiarCasosVaciosPendientes();
      if (borrados > 0) {
        this.logger.log(
          `agrupador de fraude: ${borrados} caso(s) pendiente(s) sin evidencia borrado(s)`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `agrupador de fraude: no se pudieron limpiar los casos vacios (${(error as Error)?.message ?? error})`,
      );
    }
  }
}
