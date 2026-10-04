import { Injectable, Logger } from '@nestjs/common';
import { EventoComentarioSyncService } from '../resenas/evento-comentario-sync.service';
import { ValoracionComentariosService } from '../resenas/valoracion-comentarios.service';
import { ResenasRepetidasDetectorService } from './resenas-repetidas-detector.service';
import { ResenasParecidasDetectorService } from './resenas-parecidas-detector.service';
import { AnilloDeTextoDetectorService } from './anillo-de-texto-detector.service';
import { NotasIncoherentesDetectorService } from './notas-incoherentes-detector.service';

/** La reseña recien escrita: de quien es, de que vendedor y producto. */
export interface ResenaNueva {
  idComentario: number;
  idResena: number;
  idUsuario: number;
  idVendedor: number;
  idProducto: number;
}

/**
 * El chequeo de fraude por texto de una reseña recien escrita, sin esperar a
 * los workers de 15 minutos. Es la misma estructura que los anillos del grafo
 * (`ResenasService.crear` espera a que la reseña llegue a Neo4j y lanza
 * `detectarInmediato`), pero para las senales de texto, que viven en
 * Elasticsearch:
 *
 * 1. **Indexar ya** la reseña (`EventoComentarioSyncService.procesarAhora`):
 *    pide su vector a Ollama y la deja buscable.
 * 2. **Valorarla ya** (`ValoracionComentariosService.valorarAhora`).
 * 3. **Evaluar solo esta reseña** en las cuatro senales de texto, en paralelo:
 *    `resenas_repetidas` (su cuenta), `resenas_parecidas_*` (su vendedor y su
 *    producto), `anillo_de_texto` (su vendedor) y `notas_incoherentes_*` (su
 *    cuenta, producto y vendedor).
 *
 * Lo llama `ResenasService.crear` SIN `await`: no retrasa la respuesta. Si algo
 * falla (Ollama caido, Elasticsearch, un detector), no se lanza nada ni se
 * reintenta aqui: el evento de la reseña queda en la cola y los workers
 * periodicos de cada senal la recogen en sus proximas pasadas. Cada detector
 * corta pronto si la reseña nueva no puede cambiar su resultado (por ejemplo, si
 * no tiene gemela), para no gastar CPU del backend en cada reseña.
 */
@Injectable()
export class ChequeoTextoInmediatoService {
  private readonly logger = new Logger(ChequeoTextoInmediatoService.name);

  constructor(
    private readonly eventoComentarioSyncService: EventoComentarioSyncService,
    private readonly valoracionComentariosService: ValoracionComentariosService,
    private readonly resenasRepetidasDetectorService: ResenasRepetidasDetectorService,
    private readonly resenasParecidasDetectorService: ResenasParecidasDetectorService,
    private readonly anilloDeTextoDetectorService: AnilloDeTextoDetectorService,
    private readonly notasIncoherentesDetectorService: NotasIncoherentesDetectorService,
  ) {}

  async ejecutar(resena: ResenaNueva): Promise<void> {
    try {
      await this.eventoComentarioSyncService.procesarAhora();
      await this.valoracionComentariosService.valorarAhora();
    } catch (error) {
      this.logger.warn(
        `chequeo de texto de la resena ${resena.idResena}: no se pudo indexar o valorar, lo recogen los workers (${error instanceof Error ? error.message : String(error)})`,
      );
      return;
    }

    // Cada detector atrapa sus propios errores; `allSettled` por si alguno no.
    await Promise.allSettled([
      this.resenasRepetidasDetectorService.revisarInmediato(
        resena.idUsuario,
        resena.idResena,
      ),
      this.resenasParecidasDetectorService.revisarInmediato(
        resena.idVendedor,
        resena.idProducto,
        resena.idResena,
      ),
      this.anilloDeTextoDetectorService.revisarInmediato(
        resena.idVendedor,
        resena.idResena,
      ),
      this.notasIncoherentesDetectorService.detectarInmediato(
        resena.idComentario,
      ),
    ]);
  }
}
