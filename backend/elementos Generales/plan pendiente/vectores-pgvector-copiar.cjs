// Copia a PostgreSQL (vector_producto y vector_comentario) los vectores que
// hoy estan en Elasticsearch: el campo `vector` de mesh_productos y el indice
// mesh_comentarios entero (vector y valoracion). Sin llamar a Ollama: los
// mismos numeros, asi que las busquedas y las senales dan lo mismo que antes.
// Hace falta una sola vez por base, despues de vectores-pgvector.sql y antes
// de borrar mesh_comentarios. Una base nueva no lo necesita: los vectores los
// calculan los workers (ver vectores-pgvector.md).
// Uso (desde backend/):  node "elementos Generales/plan pendiente/vectores-pgvector-copiar.cjs"
// Es idempotente (UPSERT): se puede correr las veces que haga falta.
// Lee las credenciales de backend/.env, igual que el backend.
require('dotenv').config({ path: require('path').join(__dirname, '../../.env'), quiet: true });
const { Client } = require('@elastic/elasticsearch');
const { Pool } = require('pg');

const INDICE_PRODUCTOS = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const INDICE_COMENTARIOS = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

/** Todos los documentos con vector de un indice, de a 500 (search_after). */
async function leerTodos(elastic, indice, campos) {
  const docs = [];
  let despues;
  for (;;) {
    const respuesta = await elastic.search({
      index: indice,
      size: 500,
      _source: campos,
      query: { exists: { field: 'vector' } },
      sort: [{ _doc: 'asc' }],
      search_after: despues,
    });
    const hits = respuesta.hits.hits;
    if (hits.length === 0) return docs;
    docs.push(...hits);
    despues = hits[hits.length - 1].sort;
  }
}

const aVector = (vector) => `[${vector.join(',')}]`;

(async () => {
  const elastic = new Client({
    node: `http://${process.env.ELASTIC_HOST ?? 'localhost'}:${process.env.ELASTIC_PORT ?? 9200}`,
  });
  const pool = new Pool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
  });

  const productos = await leerTodos(elastic, INDICE_PRODUCTOS, [
    'vector', 'vector_hash', 'vector_grupo', 'vector_modelo', 'estado',
  ]);
  const comentarios = await leerTodos(elastic, INDICE_COMENTARIOS, [
    'vector', 'vector_hash', 'vector_modelo', 'valoracion_texto', 'prob_mala', 'valoracion_modelo',
  ]);

  const cliente = await pool.connect();
  let copiadosProductos = 0;
  let copiadosComentarios = 0;
  try {
    await cliente.query('BEGIN');
    for (const { _id, _source: d } of productos) {
      // Solo si el producto esta en producto_catalogo (la FK lo exige). Uno que
      // no esta lo vuelve a calcular el worker cuando aparezca.
      const { rowCount } = await cliente.query(
        `INSERT INTO vector_producto (id_producto_mongo, vector, texto_hash, grupo, activo, modelo)
         SELECT $1, $2::vector, $3, $4, $5, $6
          WHERE EXISTS (SELECT 1 FROM producto_catalogo WHERE id_producto_mongo = $1)
         ON CONFLICT (id_producto_mongo) DO UPDATE SET
           vector = EXCLUDED.vector, texto_hash = EXCLUDED.texto_hash, grupo = EXCLUDED.grupo,
           activo = EXCLUDED.activo, modelo = EXCLUDED.modelo, fecha_calculo = now()`,
        [Number(_id), aVector(d.vector), d.vector_hash, d.vector_grupo, d.estado === 'activo', d.vector_modelo],
      );
      copiadosProductos += rowCount;
    }
    for (const { _id, _source: d } of comentarios) {
      // Igual: solo si el comentario todavia existe.
      const { rowCount } = await cliente.query(
        `INSERT INTO vector_comentario (id_comentario, vector, texto_hash, modelo,
                                        valoracion_texto, prob_mala, valoracion_modelo)
         SELECT $1, $2::vector, $3, $4, $5, $6, $7
          WHERE EXISTS (SELECT 1 FROM comentario WHERE id_comentario = $1)
         ON CONFLICT (id_comentario) DO UPDATE SET
           vector = EXCLUDED.vector, texto_hash = EXCLUDED.texto_hash, modelo = EXCLUDED.modelo,
           fecha_calculo = now(), valoracion_texto = EXCLUDED.valoracion_texto,
           prob_mala = EXCLUDED.prob_mala, valoracion_modelo = EXCLUDED.valoracion_modelo`,
        [
          Number(_id), aVector(d.vector), d.vector_hash, d.vector_modelo,
          d.valoracion_texto ?? null, d.prob_mala ?? null, d.valoracion_modelo ?? null,
        ],
      );
      copiadosComentarios += rowCount;
    }
    await cliente.query('COMMIT');
  } catch (error) {
    await cliente.query('ROLLBACK');
    throw error;
  } finally {
    cliente.release();
  }
  console.log(
    `copiados: ${copiadosProductos} de ${productos.length} productos, ${copiadosComentarios} de ${comentarios.length} comentarios`,
  );
  await pool.end();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
