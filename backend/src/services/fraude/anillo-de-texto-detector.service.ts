import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { elasticClient } from '../../database/elastic';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';
import {
  agruparPorParecido,
  cosenoEntre,
  media,
  norma,
  redondear,
  VectorConNorma,
} from '../../helpers/similitud-vectores';

const INDICE = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

const MS_POR_DIA = 24 * 60 * 60 * 1000;

/** Una resena de la base (autor, vendedor y fecha), sin su texto. */
interface FilaResena {
  id_resena: string;
  id_usuario: string;
  id_usuario_vendedor: string;
  fecha_publicacion: Date;
}

/** Un documento de `mesh_comentarios`, con lo que necesita este detector. */
interface DocumentoComentario {
  id_resena: number;
  comentario: string;
  vector?: number[];
}

/** Una resena lista para compararla con las demas del mismo vendedor. */
interface ResenaDelAnillo extends VectorConNorma {
  idResena: number;
  idUsuario: number;
  fecha: number;
}

/**
 * Detecta VARIAS cuentas que escribieron resenas casi iguales sobre el mismo
 * vendedor, en fechas cercanas: un anillo de texto, la firma de una red de
 * bots o de cuentas coordinadas que usan la misma plantilla. Es la senal
 * `anillo_de_texto` de la familia `patron_resenas`, con fuente `elastic`. La
 * hermana de `ResenasRepetidasDetectorService`, que mira UNA cuenta que se
 * repite. Ver `elementos Generales/plan pendiente/anillo-de-texto.md`.
 *
 * El texto de cada resena vive, con su vector, en `mesh_comentarios`
 * (`EventoComentarioSyncService`); el autor, el vendedor y la fecha, en
 * PostgreSQL. Aca se cruzan los dos:
 *
 * 1. PostgreSQL saca los vendedores con resenas de `MIN_CUENTAS` o mas autores
 *    distintos en la ventana, y las resenas de cada uno.
 * 2. De esas resenas se traen sus vectores de Elasticsearch, y se descartan
 *    las de menos de `MIN_CARACTERES`.
 * 3. Dos resenas se unen si son de AUTORES DISTINTOS, se escribieron con no
 *    mas de `DIAS_ENTRE_RESENAS` de diferencia y su coseno pasa de
 *    `UMBRAL_COSENO`. Un grupo son las que se unen, directa o encadenadamente.
 * 4. Si un grupo tiene `MIN_CUENTAS` o mas autores distintos, es un anillo.
 *    Una senal por grupo (`clave` = los ids de sus cuentas, ordenados y unidos
 *    con guion, como los demas anillos), con todas sus resenas de evidencia.
 *
 * Solo se mira DENTRO de un vendedor: una plantilla repetida por gente que
 * califica a vendedores distintos es una frase comun, no un anillo. Limite
 * conocido: una red que reparte su plantilla entre muchos vendedores, de a
 * pocas cuentas cada uno, no se ve.
 *
 * No hay chequeo por resena: a diferencia de los anillos del grafo, un anillo
 * de texto se forma con varias resenas, y el periodico cada 15 min alcanza.
 * Mismo molde que `PatronesFraudeDetectorService`: `@Interval`, bandera
 * `procesando`, y un error de conexion se loguea y no tumba el proceso.
 */
@Injectable()
export class AnilloDeTextoDetectorService {
  private readonly logger = new Logger(AnilloDeTextoDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Solo cuentan las resenas de los ultimos dias. Igual que
   * `ResenasRepetidasDetectorService.VENTANA_DIAS`. */
  private static readonly VENTANA_DIAS = 180;

  /** Cuentas distintas que hacen falta para que un grupo sea un anillo. */
  private static readonly MIN_CUENTAS = 3;

  /** Una resena de menos caracteres que esto no cuenta. */
  private static readonly MIN_CARACTERES = 40;

  /** Coseno desde el cual dos resenas se consideran casi iguales. */
  private static readonly UMBRAL_COSENO = 0.92;

  /** Dos resenas solo se unen si se escribieron con tan pocos dias de
   * diferencia: una plantilla repetida a lo largo de meses es otra cosa. */
  private static readonly DIAS_ENTRE_RESENAS = 30;

  /** Tope de resenas que se comparan por vendedor (las mas recientes): la
   * comparacion es de todas contra todas. */
  private static readonly MAX_RESENAS_POR_VENDEDOR = 1000;

  private procesando = false;

  @Interval(
    'anillo-de-texto-detector',
    AnilloDeTextoDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const porVendedor = await this.resenasPorVendedor();
      let anillos = 0;
      for (const [idVendedor, filas] of porVendedor) {
        anillos += await this.revisarVendedor(idVendedor, filas);
      }
      this.logger.log(
        `worker de anillos de texto: ${porVendedor.size} vendedor(es) revisados, ${anillos} anillo(s)`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de anillos de texto interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /** Las resenas de la ventana de cada vendedor con `MIN_CUENTAS` o mas autores
   * distintos -- el resto no puede formar un anillo. */
  private async resenasPorVendedor(): Promise<Map<string, FilaResena[]>> {
    const { rows } = await pool.query<FilaResena>(
      `WITH recientes AS (
         SELECT r.id_resena, r.id_usuario, r.id_usuario_vendedor,
                c.fecha_publicacion
           FROM resena r
           JOIN comentario c ON c.id_comentario = r.id_comentario
          WHERE c.fecha_publicacion >= now() - make_interval(days => $1)
       )
       SELECT id_resena, id_usuario, id_usuario_vendedor, fecha_publicacion
         FROM recientes
        WHERE id_usuario_vendedor IN (
                SELECT id_usuario_vendedor FROM recientes
                 GROUP BY id_usuario_vendedor
                HAVING count(DISTINCT id_usuario) >= $2)
        ORDER BY id_usuario_vendedor, fecha_publicacion DESC`,
      [
        AnilloDeTextoDetectorService.VENTANA_DIAS,
        AnilloDeTextoDetectorService.MIN_CUENTAS,
      ],
    );
    const porVendedor = new Map<string, FilaResena[]>();
    for (const fila of rows) {
      const lista = porVendedor.get(fila.id_usuario_vendedor) ?? [];
      lista.push(fila);
      porVendedor.set(fila.id_usuario_vendedor, lista);
    }
    return porVendedor;
  }

  /** Devuelve cuantos anillos quedaron como senal en este vendedor. */
  private async revisarVendedor(
    idVendedor: string,
    filas: FilaResena[],
  ): Promise<number> {
    const recientes = filas.slice(
      0,
      AnilloDeTextoDetectorService.MAX_RESENAS_POR_VENDEDOR,
    );
    const resenas = await this.cargarVectores(recientes);
    const cuentasDistintas = new Set(resenas.map((r) => r.idUsuario));
    if (cuentasDistintas.size < AnilloDeTextoDetectorService.MIN_CUENTAS) {
      return 0;
    }

    const msEntre =
      AnilloDeTextoDetectorService.DIAS_ENTRE_RESENAS * MS_POR_DIA;
    const grupos = agruparPorParecido(resenas.length, (a, b) => {
      const ra = resenas[a];
      const rb = resenas[b];
      if (ra.idUsuario === rb.idUsuario) {
        return null; // una cuenta repetida es la otra senal
      }
      if (Math.abs(ra.fecha - rb.fecha) > msEntre) {
        return null;
      }
      const coseno = cosenoEntre(ra, rb);
      return coseno >= AnilloDeTextoDetectorService.UMBRAL_COSENO
        ? coseno
        : null;
    });

    let anillos = 0;
    for (const grupo of grupos) {
      const miembros = grupo.indices.map((i) => resenas[i]);
      const cuentas = [...new Set(miembros.map((m) => m.idUsuario))].sort(
        (a, b) => a - b,
      );
      if (cuentas.length < AnilloDeTextoDetectorService.MIN_CUENTAS) {
        continue;
      }
      const fechas = miembros.map((m) => m.fecha);
      try {
        await registrarAnilloFraude({
          tipo: 'anillo_de_texto',
          clave: cuentas.join('-'),
          resenas: miembros.map((m) => m.idResena).sort((a, b) => a - b),
          detalle: {
            vendedor: Number(idVendedor),
            cuentas: cuentas.length,
            resenas_en_grupo: miembros.length,
            dias_de_diferencia: Math.ceil(
              (Math.max(...fechas) - Math.min(...fechas)) / MS_POR_DIA,
            ),
            similitud_media: redondear(media(grupo.valores)),
            similitud_minima: redondear(Math.min(...grupo.valores)),
            umbral_coseno: AnilloDeTextoDetectorService.UMBRAL_COSENO,
            min_caracteres: AnilloDeTextoDetectorService.MIN_CARACTERES,
            dias_entre_resenas: AnilloDeTextoDetectorService.DIAS_ENTRE_RESENAS,
            ventana_dias: AnilloDeTextoDetectorService.VENTANA_DIAS,
          },
        });
        anillos++;
      } catch (error) {
        this.logger.warn(
          `no se pudo persistir el anillo de texto ${cuentas.join('-')} del vendedor ${idVendedor}: ${mensajeCorto(error)}`,
        );
      }
    }
    return anillos;
  }

  /** Los vectores de esas resenas, de Elasticsearch. Una sin vector, o de menos
   * de `MIN_CARACTERES`, no entra. Solo resenas raiz: las respuestas no. */
  private async cargarVectores(
    filas: FilaResena[],
  ): Promise<ResenaDelAnillo[]> {
    const porId = new Map(filas.map((f) => [Number(f.id_resena), f]));
    const respuesta = await elasticClient.search<DocumentoComentario>({
      index: INDICE,
      size: filas.length,
      _source: ['id_resena', 'comentario', 'vector'],
      query: {
        bool: {
          filter: [
            { term: { es_respuesta: false } },
            { terms: { id_resena: [...porId.keys()] } },
          ],
        },
      },
    });

    const resenas: ResenaDelAnillo[] = [];
    for (const hit of respuesta.hits.hits) {
      const fuente = hit._source;
      const fila = fuente ? porId.get(fuente.id_resena) : undefined;
      if (
        fuente?.vector == null ||
        fila == null ||
        fuente.comentario.trim().length <
          AnilloDeTextoDetectorService.MIN_CARACTERES
      ) {
        continue;
      }
      resenas.push({
        idResena: fuente.id_resena,
        idUsuario: Number(fila.id_usuario),
        fecha: new Date(fila.fecha_publicacion).getTime(),
        vector: fuente.vector,
        norma: norma(fuente.vector),
      });
    }
    return resenas;
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
