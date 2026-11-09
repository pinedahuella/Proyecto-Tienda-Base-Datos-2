// servidor.mjs
// Panel de comandos de Mesh. Una pagina con botones que lanzan de verdad los
// comandos de comandos.txt (arrancar.ps1, las semillas, las demos de fraude).
//
//   node panel-comandos/servidor.mjs        o        .\panel-comandos.ps1
//   http://127.0.0.1:5199
//
// No lleva dependencias: solo Node. Vive APARTE de la aplicacion a proposito.
// Los botones de arrancar hacen falta justo cuando el backend y el frontend
// estan apagados, y una pestana dentro de la app no existiria en ese momento.
//
// Que lo hace seguro de dejar corriendo:
//   1. Escucha solo en 127.0.0.1, nadie de la red lo ve.
//   2. Solo ejecuta lo que esta en CATALOGO. No hay ruta que reciba un comando
//      libre, y cada valor se valida contra un patron antes de armar nada.
//   3. Cada peticion trae un token que solo esta en la pagina que sirve este
//      mismo servidor. Otra pagina abierta en el navegador no puede leerlo, asi
//      que no puede disparar comandos.
//   4. Se rechaza cualquier Host que no sea 127.0.0.1 o localhost con este
//      puerto, contra el rebinding de DNS.
//   5. Los comandos que borran piden confirmacion, y la exige el SERVIDOR: un
//      fetch armado a mano sin la confirmacion tambien se rechaza.

import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { StringDecoder } from 'node:string_decoder';
import { fileURLToPath } from 'node:url';

const AQUI = path.dirname(fileURLToPath(import.meta.url));
const RAIZ = path.resolve(AQUI, '..');
const PUERTO = Number(process.env.PANEL_PUERTO || 5199);
const TOKEN = randomBytes(24).toString('hex');
// Los unicos origenes de frontend que pueden hablarle a este servidor y pedirle el
// token. Ver el comentario de CORS mas abajo.
const FRONTENDS_OK = ['http://localhost:5173', 'http://127.0.0.1:5173', 'https://mesh.ledkid.com'];

// ---------------------------------------------------------------------------
// El catalogo. Todo lo que el panel puede hacer esta aqui y en ningun otro lado.
// La pagina arma sus formularios leyendo esta lista, asi que agregar un comando
// es agregar una entrada, sin tocar el HTML.
//
//   script      ruta relativa a la raiz del repo
//   campos      lo que se le pide a quien usa el panel, cada uno validado
//   confirmar   null, 'SI' (una casilla) o un texto que hay que escribir igual
//   construir   recibe los valores ya validados y devuelve los argumentos
// ---------------------------------------------------------------------------

const ARRANCAR = 'arrancar.ps1';
const SERVICIOS = 'panel-comandos/servicios.ps1';
const CAIDAS = 'remoto/caidas.ps1';
const BASES_CAIDA = ['postgres', 'mongo', 'redis', 'neo4j', 'clickhouse', 'elastic', 'todas'];

const CATALOGO = [
  // --- Arrancar y parar ---------------------------------------------------
  {
    id: 'todo', grupo: 'Arrancar y parar', titulo: 'Levantar todo',
    explica: 'Las bases, el backend y el frontend, en ese orden, y al final abre https://mesh.ledkid.com si esta configurada. Es el de todos los dias y no borra nada. Tarda unos tres minutos.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'todo'],
  },
  {
    id: 'estado', grupo: 'Arrancar y parar', titulo: 'Ver que esta corriendo',
    explica: 'Puertos del backend y del frontend, contenedores y memoria libre.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'estado'],
  },
  {
    id: 'bases', grupo: 'Arrancar y parar', titulo: 'Solo las bases de datos',
    explica: 'Arranca Docker si esta apagado, levanta los contenedores y aplica las migraciones que falten. No borra datos.',
    script: ARRANCAR, campos: [], confirmar: null,
    construir: () => [],
  },
  {
    id: 'backend', grupo: 'Arrancar y parar', titulo: 'Reiniciar el backend',
    explica: 'Lo compila otra vez y lo vuelve a levantar en el 3000. Usalo despues de cambiar codigo del backend.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'backend'],
  },
  {
    id: 'frontend', grupo: 'Arrancar y parar', titulo: 'Reiniciar el frontend',
    explica: 'Lo compila otra vez y lo sirve en el 5173. Usalo despues de cambiar codigo de la tienda.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'frontend'],
  },
  {
    id: 'parar-backend', grupo: 'Arrancar y parar', titulo: 'Parar el backend',
    explica: 'Solo el proceso de Mesh. No toca las bases ni otros proyectos.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'parar-backend'],
  },
  {
    id: 'parar-frontend', grupo: 'Arrancar y parar', titulo: 'Parar el frontend',
    explica: 'Solo el proceso de Mesh. No toca las bases ni otros proyectos.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'parar-frontend'],
  },
  {
    id: 'publicar', grupo: 'Arrancar y parar', titulo: 'Abrir mesh.ledkid.com',
    explica: 'Publica la tienda en https://mesh.ledkid.com para que cualquiera pueda entrar y registrarse, con su IP real. Es un tunel aparte del de LEDKID, que no se toca. Ojo: quien conozca las cuentas de prueba entra con ellas, admin incluido.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'publico'],
  },
  {
    id: 'despublicar', grupo: 'Arrancar y parar', titulo: 'Cerrar mesh.ledkid.com',
    explica: 'Cierra la direccion publica. La tienda sigue en local, y ledkid.com no se toca.',
    script: SERVICIOS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'despublicar'],
  },

  // --- Productos de prueba ------------------------------------------------
  {
    id: 'productos', grupo: 'Productos de prueba', titulo: 'Generar productos con semilla',
    explica: 'Agrega productos inventados con sus variantes, imagenes y ofertas. No borra lo que ya hay. La misma semilla da siempre el mismo lote.',
    script: ARRANCAR, confirmar: null,
    campos: [
      { nombre: 'cantidad', etiqueta: 'Cuantos', tipo: 'entero', min: 1, max: 9999, defecto: 100 },
      { nombre: 'semilla', etiqueta: 'Semilla, vacio elige una libre', tipo: 'entero', min: 0, max: 999999999, opcional: true },
    ],
    construir: (v) => ['-Productos', v.cantidad, ...(v.semilla ? ['-Semilla', v.semilla] : [])],
  },
  {
    id: 'borrar-lote', grupo: 'Productos de prueba', titulo: 'Borrar productos generados',
    explica: 'Borra los mas nuevos de los generados, o todos. Con semilla borra solo el lote de esa semilla. No toca el catalogo curado.',
    script: ARRANCAR, confirmar: 'SI',
    peligro: 'Borra productos de PostgreSQL y de MongoDB. No se deshace.',
    campos: [
      { nombre: 'cuantos', etiqueta: 'Cuantos, o la palabra todos', tipo: 'texto', patron: '^(\\d{1,5}|todos)$', defecto: 'todos' },
      { nombre: 'semilla', etiqueta: 'Solo de esta semilla, opcional', tipo: 'entero', min: 0, max: 999999999, opcional: true },
    ],
    construir: (v) => ['-Borrar', v.cuantos, ...(v.semilla ? ['-Semilla', v.semilla] : [])],
  },
  {
    id: 'productos-mongo', grupo: 'Productos de prueba', titulo: 'Generar productos que viven solo en MongoDB',
    explica: 'Como los que crea un vendedor desde su panel. Van a MongoDB y no a PostgreSQL.',
    script: ARRANCAR, confirmar: null,
    campos: [
      { nombre: 'cantidad', etiqueta: 'Cuantos', tipo: 'entero', min: 1, max: 9999, defecto: 50 },
      { nombre: 'semilla', etiqueta: 'Semilla, opcional', tipo: 'entero', min: 0, max: 999999999, opcional: true },
    ],
    construir: (v) => ['-ProductosMongo', v.cantidad, ...(v.semilla ? ['-Semilla', v.semilla] : [])],
  },
  {
    id: 'borrar-mongo', grupo: 'Productos de prueba', titulo: 'Borrar un lote de MongoDB',
    explica: 'Borra el lote de esa semilla en las dos bases.',
    script: ARRANCAR, confirmar: 'SI',
    peligro: 'Borra el lote de las dos bases. No se deshace.',
    campos: [{ nombre: 'semilla', etiqueta: 'Semilla del lote', tipo: 'entero', min: 0, max: 999999999 }],
    construir: (v) => ['-BorrarMongo', v.semilla],
  },
  {
    id: 'etl', grupo: 'Productos de prueba', titulo: 'Volver a migrar catalogo y grafo',
    explica: 'Copia el catalogo de PostgreSQL a MongoDB y las reseñas a Neo4j. Solo suma, no borra.',
    script: ARRANCAR, campos: [], confirmar: null,
    construir: () => ['-Etl'],
  },

  // --- Reconstruir bases --------------------------------------------------
  {
    id: 'reiniciar-grafo', grupo: 'Reconstruir bases', titulo: 'Rehacer el grafo de Neo4j',
    explica: 'Vacia el grafo y lo reconstruye desde PostgreSQL. Arregla nodos de producto sobrantes. Se pierde cualquier cosa sembrada a mano en Neo4j.',
    script: ARRANCAR, confirmar: 'SI',
    peligro: 'Vacia Neo4j antes de reconstruirlo.',
    campos: [],
    construir: () => ['-ReiniciarGrafo'],
  },
  {
    id: 'reiniciar-mongo', grupo: 'Reconstruir bases', titulo: 'Rehacer MongoDB',
    explica: 'Rehace solo MongoDB y no toca PostgreSQL. Los productos que vivian solo en Mongo se pierden.',
    script: ARRANCAR, confirmar: 'SI',
    peligro: 'Borra MongoDB entero.',
    campos: [],
    construir: () => ['-ReiniciarMongo'],
  },
  {
    id: 'reiniciar-todo', grupo: 'Reconstruir bases', titulo: 'Borrar todo y empezar de cero',
    explica: 'Borra las seis bases y las vuelve a construir desde los archivos del repositorio. Se van pedidos, cuentas creadas, reseñas y carritos, incluidas las cuentas desarrollador. Tarda unos dos minutos.',
    script: ARRANCAR, confirmar: 'BORRAR TODO',
    peligro: 'Esto no se deshace. Se pierde todo lo que se hizo a mano.',
    campos: [],
    construir: () => ['-Reiniciar'],
  },

  // --- Demos de fraude ----------------------------------------------------
  {
    id: 'entrar-pais', grupo: 'Demos de fraude', titulo: 'Entrar a Mesh desde otro pais',
    explica: 'Agrega un pais: te da un link con su nombre (mesh-singapur.ledkid.com) que abre la tienda real vista desde ese pais, en cualquier navegador o en el celular, y ademas abre una ventana de Chrome ya puesta en ese pais. No cierra los otros paises que ya tengas abiertos. Para el viaje imposible entra con la misma cuenta desde dos paises.',
    script: 'demo-entrar-otro-pais.ps1', confirmar: null,
    campos: [
      { nombre: 'pais', etiqueta: 'Pais', tipo: 'opcion', opciones: ['sg', 'de', 'jp', 'us', 'nl', 'fr', 'gb', 'ca'], defecto: 'sg' },
    ],
    construir: (v) => ['-Pais', v.pais],
  },
  {
    id: 'entrar-paises', grupo: 'Demos de fraude', titulo: 'Abrir varios paises a la vez',
    explica: 'Marca los paises y se abre un link por cada uno, todos a la vez, para ensenar que tu escoges desde donde se entra. Abre exactamente los que marques y cierra los otros. Cada pais es un Tor de casi 100 MB: con los ocho la maquina puede ir lenta, para ensenar bastan dos o tres.',
    script: 'demo-entrar-otro-pais.ps1', confirmar: null,
    campos: [
      {
        nombre: 'paises', etiqueta: 'Paises', tipo: 'multiple', defecto: 'sg,de',
        opciones: ['sg', 'de', 'jp', 'us', 'nl', 'fr', 'gb', 'ca'],
        rotulos: { sg: 'Singapur', de: 'Alemania', jp: 'Japon', us: 'EE. UU.', nl: 'Holanda', fr: 'Francia', gb: 'Reino Unido', ca: 'Canada' },
      },
    ],
    construir: (v) => ['-Paises', v.paises],
  },
  {
    id: 'entrar-pais-estado', grupo: 'Demos de fraude', titulo: 'Ver desde donde salgo',
    explica: 'Muestra que paises estan abiertos: su contenedor de Tor en Docker, la IP y el pais con los que sale, y si su link contesta.',
    script: 'demo-entrar-otro-pais.ps1', campos: [], confirmar: null,
    construir: () => ['-Estado'],
  },
  {
    id: 'entrar-pais-cerrar', grupo: 'Demos de fraude', titulo: 'Acabar el tour: cerrar todos los paises',
    explica: 'Cierra TODOS los paises abiertos: sus links, sus Tor y la ventana de Chrome. Tus otras ventanas no se tocan, y mesh.ledkid.com sigue como estaba.',
    script: 'demo-entrar-otro-pais.ps1', campos: [], confirmar: null,
    construir: () => ['-Cerrar'],
  },
  {
    id: 'demo-evento', grupo: 'Demos de fraude', titulo: 'Disparar una senal de login',
    explica: 'Peticiones directas al backend que cruzan el umbral de una sola senal y la confirman en la base. Abre el panel de fraude al final. Si corres varias en menos de cinco minutos los contadores se acumulan.',
    script: 'demo-evento-fraude.ps1', confirmar: null,
    campos: [
      { nombre: 'tipo', etiqueta: 'Senal', tipo: 'opcion', opciones: ['fuerza_bruta_cuenta', 'fuerza_bruta_ip', 'multi_cuenta_ip'], defecto: 'fuerza_bruta_cuenta' },
      { nombre: 'cuenta', etiqueta: 'Cuenta objetivo, no aplica a multi_cuenta_ip', tipo: 'texto', patron: '^[A-Za-z0-9._-]{1,40}@[A-Za-z0-9.-]{1,40}$', defecto: 'ventas.norte@mesh.com' },
    ],
    construir: (v) => ['-Tipo', v.tipo, ...(v.tipo === 'multi_cuenta_ip' ? [] : ['-Cuenta', v.cuenta])],
  },
  {
    id: 'demo-anillo', grupo: 'Demos de fraude', titulo: 'Armar un anillo de reseñas',
    explica: 'Crea cuentas que se compran y se califican entre si en circulo, con compras reales, y el detector las encuentra en unos segundos. Las cuentas quedan como prefijo1, prefijo2 y asi, con la contrasena Desarrollo123!.',
    script: 'demo-anillo-resenas.ps1', confirmar: 'SI',
    peligro: 'Deja pedidos y movimientos de inventario reales. No hay como deshacerlo.',
    campos: [
      { nombre: 'cuentas', etiqueta: 'Cuantas cuentas', tipo: 'opcion', opciones: ['2', '3', '4'], defecto: '3' },
      { nombre: 'prefijo', etiqueta: 'Prefijo de las cuentas', tipo: 'texto', patron: '^[A-Za-z0-9]{1,20}$', defecto: 'desarrollador' },
    ],
    construir: (v) => ['-Cuentas', v.cuentas, '-Prefijo', v.prefijo],
  },
  {
    id: 'demo-patrones', grupo: 'Demos de fraude', titulo: 'Patrones de resenas que salen al instante',
    explica: 'Cuentas nuevas que compran y califican de verdad. favor: dos cuentas se ponen 5 una a la otra en minutos y sale como mutuo, con las horas de ida y vuelta como bono. coordinados: dos cuentas califican los mismos productos a la vez. Cada caso sale en segundos en Fraude, Resenas en anillo, filtrando por su tipo. A los 15 minutos el worker suma Reputacion en minutos con estas mismas cuentas.',
    script: 'demo-patrones-resenas.ps1', confirmar: 'SI',
    peligro: 'Deja cuentas, pedidos y movimientos de inventario reales. No hay como deshacerlo.',
    campos: [
      { nombre: 'patron', etiqueta: 'Patron', tipo: 'opcion', opciones: ['todos', 'favor', 'coordinados'], defecto: 'todos' },
    ],
    construir: (v) => ['-Patron', v.patron],
  },
  {
    id: 'demo-pais-precalentar', grupo: 'Demos de fraude', titulo: 'Precalentar la demo de otro pais',
    explica: 'Hazlo antes de la clase. Comprueba que el tunel pueda salir (en la U conecta WARP), construye la imagen de Tor y deja Tor con salida en el pais. No apaga nada de Mesh. Despues la demo arranca mas rapido. Tor queda corriendo, casi 100 MB.',
    script: 'demo-fraude-pais.ps1', confirmar: null,
    campos: [
      { nombre: 'pais', etiqueta: 'Pais', tipo: 'opcion', opciones: ['sg', 'de', 'jp', 'us', 'nl', 'fr', 'gb', 'ca'], defecto: 'sg' },
    ],
    construir: (v) => ['-Precalentar', '-Pais', v.pais],
  },
  {
    id: 'demo-pais', grupo: 'Demos de fraude', titulo: 'Login desde otro pais',
    explica: 'Usa Tor de verdad para intentar entrar desde la IP de otro pais y confirma en las bases que salto la alerta. Al final te da un link con el nombre del pais (mesh-singapur.ledkid.com) para entrar TU MISMO desde ese pais, en cualquier navegador, y lo deja abierto hasta que lo cierres. Mesh sigue funcionando todo el rato. Abre la direccion publica si estaba cerrada.',
    script: 'demo-fraude-pais.ps1', confirmar: null,
    campos: [
      { nombre: 'pais', etiqueta: 'Pais', tipo: 'opcion', opciones: ['sg', 'de', 'jp', 'us', 'nl', 'fr', 'gb', 'ca'], defecto: 'sg' },
    ],
    construir: (v) => ['-Pais', v.pais],
  },
  {
    id: 'demo-pais-limpiar', grupo: 'Demos de fraude', titulo: 'Borrar lo que sembro la demo de pais',
    explica: 'Quita la alerta de PostgreSQL, Mongo y Elastic.',
    script: 'demo-fraude-pais.ps1', confirmar: 'SI',
    peligro: 'Borra las alertas de esa demo.',
    campos: [],
    construir: () => ['-Limpiar'],
  },

  // --- Demo de descuentos -------------------------------------------------
  {
    id: 'demo-descuentos', grupo: 'Demo de descuentos', titulo: 'Descuentos que se activan y se apagan solos',
    explica: 'Un vendedor nuevo con dos ofertas. regla: tres compras reales cruzan el umbral de una regla y el worker aplica el descuento en menos de un minuto. manual: un descuento con vencimiento corto, que PostgreSQL guarda en oferta.fecha_vencimiento_descuento y el panel del vendedor ensena como hasta las HH:MM; al vencer el worker lo quita y el historial de precio lo anota a nombre de la tienda. Al final borra la regla, retira las ofertas y quita las ventas de ClickHouse. Tarda unos cuatro minutos.',
    script: 'demo-descuentos-solos.ps1', confirmar: 'SI',
    peligro: 'Deja cuentas nuevas y, con la regla, tres pedidos reales en PostgreSQL. Eso no se deshace.',
    campos: [
      { nombre: 'parte', etiqueta: 'Parte', tipo: 'opcion', opciones: ['todo', 'regla', 'manual'], defecto: 'todo' },
      { nombre: 'duracion', etiqueta: 'Segundos del descuento manual', tipo: 'entero', min: 30, max: 60, defecto: 45 },
    ],
    construir: (v) => ['-Parte', v.parte, '-Duracion', v.duracion],
  },

  // --- Caida de una base --------------------------------------------------
  // Lo que pidio el profesor: apagar una base en vivo y ver que la tienda sigue.
  // Funciona igual con las bases aqui que en otra PC: remoto/interruptor.cjs se
  // pone entre el backend y cada base, y apagarla es dejar de reenviar su puerto.
  // Ver remoto/caidas.ps1 y docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md.
  {
    id: 'caida-preparar', grupo: 'Caida de una base', titulo: 'Preparar la demo de caidas',
    explica: 'Levanta el interruptor y reinicia el backend apuntado a el. Desde ahi cada base se puede apagar y prender sin tocar la maquina que la tiene. Tarda unos tres minutos, lo que tarda el backend en arrancar.',
    script: CAIDAS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'levantar'],
  },
  {
    id: 'caida-apagar', grupo: 'Caida de una base', titulo: 'Apagar una base',
    explica: 'Apagada es como un docker stop: la base rechaza la conexion al instante. Congelada es la red cortada: acepta y no contesta, y el backend espera su limite antes de darla por caida. Abre la tienda y mira que sigue saliendo.',
    script: CAIDAS, confirmar: null,
    campos: [
      { nombre: 'base', etiqueta: 'Base', tipo: 'opcion', opciones: BASES_CAIDA, defecto: 'redis' },
      { nombre: 'como', etiqueta: 'Como', tipo: 'opcion', opciones: ['apagar', 'congelar'], defecto: 'apagar' },
    ],
    construir: (v) => ['-Accion', v.como, '-Base', v.base],
  },
  {
    id: 'caida-prender', grupo: 'Caida de una base', titulo: 'Prender una base',
    explica: 'La vuelve a conectar. El backend la usa otra vez solo, en unos 15 segundos, sin reiniciar nada.',
    script: CAIDAS, confirmar: null,
    campos: [{ nombre: 'base', etiqueta: 'Base', tipo: 'opcion', opciones: BASES_CAIDA, defecto: 'redis' }],
    construir: (v) => ['-Accion', 'prender', '-Base', v.base],
  },
  {
    id: 'caida-estado', grupo: 'Caida de una base', titulo: 'Ver que bases estan apagadas',
    explica: 'Como ve el backend cada base a traves del interruptor.',
    script: CAIDAS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'estado'],
  },
  {
    id: 'caida-quitar', grupo: 'Caida de una base', titulo: 'Terminar la demo de caidas',
    explica: 'Reinicia el backend hablando directo con las bases y apaga el interruptor. Tarda unos tres minutos.',
    script: CAIDAS, campos: [], confirmar: null,
    construir: () => ['-Accion', 'quitar'],
  },

  // --- Demo de Redis ------------------------------------------------------
  {
    id: 'redis-sin-ttl', grupo: 'Demo de Redis', titulo: 'Dejar llaves sin TTL para explicarlas',
    explica: 'Deja en Redis dos llaves que no vencen nunca (TTL -1, en RedisInsight dice No limit) y una que si vence en 10 minutos y cuenta hacia atras, para ensenar la diferencia. Estan bajo mesh:demo y no tocan nada real. Al final imprime lo que hay que explicar.',
    script: 'demo-redis-sin-ttl.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Accion', 'crear'],
  },
  {
    id: 'redis-ver-ttl', grupo: 'Demo de Redis', titulo: 'Ver las llaves de Mesh y su TTL',
    explica: 'Lista todas las llaves mesh:* con su tipo y cuanto les queda de vida. Sirve para ver bajar el TTL de la llave que vence, o para ver cuales llaves reales no tienen TTL.',
    script: 'demo-redis-sin-ttl.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Accion', 'ver'],
  },
  {
    id: 'redis-borrar-demo', grupo: 'Demo de Redis', titulo: 'Quitar las llaves de la demo',
    explica: 'Borra solo las que empiezan con mesh:demo. El carrito, los contadores de fraude y las ofertas no se tocan.',
    script: 'demo-redis-sin-ttl.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Accion', 'borrar'],
  },

  // --- Demos de la Entrega final ------------------------------------------
  {
    id: 'final-acceso', grupo: 'Demos de la Entrega final', titulo: 'Quien puede que en Redis',
    explica: 'Los usuarios de Redis intentan lo mismo y se ve que contesta Redis. El del backend solo toca las claves mesh:* y no puede vaciar ni configurar, el de los scripts tampoco administra, el de RedisInsight solo mira, y el de mantenimiento puede todo. Lo que borraria algo no se ejecuta, se le pregunta a Redis si lo dejaria.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Parte', 'acceso'],
  },
  {
    id: 'final-bases', grupo: 'Demos de la Entrega final', titulo: 'Quien puede que en las seis bases',
    explica: 'Corre la prueba del control de acceso de todas las bases. En PostgreSQL, MongoDB, ClickHouse y Elasticsearch el usuario del backend lee y escribe pero no puede crear ni borrar tablas, colecciones, indices ni usuarios, y el de solo lectura solo mira. Neo4j contesta que su edicion no tiene roles. Al final la de Redis. Tarda unos dos minutos y no cambia nada de la tienda.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Parte', 'bases'],
  },
  {
    id: 'final-semantica', grupo: 'Demos de la Entrega final', titulo: 'Productos parecidos por su descripcion',
    explica: 'Busca un producto por nombre y ensena los seis que mas se le parecen, primero los de su categoria, con su puntaje: 0,7 del parecido de nombre, categoria y descripcion, 0,2 del de sus caracteristicas y 0,1 de la nota de sus resenas. Los vectores viven en PostgreSQL, en vector_producto (pgvector): compara cuanto tarda con el indice HNSW y comparando contra todos, y que den lo mismo. Al final se los pide a la ruta de la ficha, GET /productos/:id/similares, y comprueba que sean los mismos. Si el backend esta apagado, ese ultimo paso solo avisa.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'producto', etiqueta: 'Palabra del nombre', tipo: 'texto', patron: '^[A-Za-z0-9 ]{2,30}$', defecto: 'laptop' },
    ],
    construir: (v) => ['-Parte', 'semantica', '-Producto', v.producto],
  },
  {
    id: 'final-facetas', grupo: 'Demos de la Entrega final', titulo: 'Filtros del buscador y palabras mal escritas',
    explica: 'Busca una palabra y ensena cuantos hay por categoria, precio y calificacion, que pasa al elegir una categoria, la misma palabra mal escrita y el autocompletado. Despues lo mismo por las rutas de la app, el facetado de /buscar y las sugerencias. Solo lee.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'texto', etiqueta: 'Que buscar', tipo: 'texto', patron: '^[A-Za-z0-9 ]{3,30}$', defecto: 'laptop' },
    ],
    construir: (v) => ['-Parte', 'facetas', '-Texto', v.texto],
  },
  {
    id: 'final-vectores', grupo: 'Demos de la Entrega final', titulo: 'Quien mantiene los vectores al dia',
    explica: 'Cuantos productos tienen vector en vector_producto y cuantas resenas el suyo en vector_comentario (PostgreSQL), cuantos esperan a los workers del backend (los que un vendedor creo o edito, las resenas nuevas) y si el backend llega a Ollama con el modelo descargado. Solo lee.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Parte', 'vectores'],
  },
  {
    id: 'final-rastro', grupo: 'Demos de la Entrega final', titulo: 'Lo que ClickHouse guarda de una busqueda con filtros',
    explica: 'Hace una busqueda con filtros por el backend, igual que /buscar, y ensena la fila que quedo en ClickHouse con la categoria, el precio y la disponibilidad elegidos. Despues el ranking de categorias filtradas que ve el admin en Tendencias. Al final borra esa fila, asi que las tendencias quedan como estaban. Necesita el backend.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'texto', etiqueta: 'Que buscar', tipo: 'texto', patron: '^[A-Za-z0-9 ]{3,30}$', defecto: 'laptop' },
    ],
    construir: (v) => ['-Parte', 'rastro', '-Texto', v.texto],
  },
  {
    id: 'final-compartir', grupo: 'Demos de la Entrega final', titulo: 'Compartir una oferta, el ACL de la aplicacion',
    explica: 'ventas.norte le da a ventas.sur ver y editar sobre una oferta suya. Sin permiso ventas.sur recibe 404, con ver ve pero no pone descuento, con editar cambia la existencia, y cuando ventas.norte le quita editar deja de poder al instante. Al final el registro de la oferta con el intento negado. Deja la oferta como estaba. Necesita el backend.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Parte', 'compartir'],
  },
  {
    id: 'final-permisos', grupo: 'Demos de la Entrega final', titulo: 'Permisos por rol, el ACL de funcionalidades',
    explica: 'La matriz de permisos_por_rol en PostgreSQL y cada rol llamando directo a las mismas rutas, sin la pagina. Sin sesion 401, sin el permiso 403 con el permiso que falta. En vivo, una linea de SQL le quita ofertas.publicar al vendedor y su peticion siguiente da 403, sin reiniciar nada, y otra linea se lo devuelve. Al final el registro de auditoria_permiso. Deja la matriz como estaba. Necesita el backend.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Parte', 'permisos'],
  },
  {
    id: 'final-categorias', grupo: 'Demos de la Entrega final', titulo: 'Tambien compraron, primero la misma categoria',
    explica: 'Para un producto comprado, lo que contesta Neo4j con el grupo de cada recomendacion (0 la misma categoria, 1 el resto) y lo mismo por la ruta de la ficha. Los de la misma categoria van primero aunque tengan menos compradores. Solo lee.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'producto', etiqueta: 'Palabra del nombre', tipo: 'texto', patron: '^[A-Za-z0-9 ]{2,30}$', defecto: 'laptop' },
    ],
    construir: (v) => ['-Parte', 'categorias', '-Producto', v.producto],
  },

  // --- Demos de resenas ---------------------------------------------------
  {
    id: 'resenas-intencion', grupo: 'Demos de resenas', titulo: 'Buscar por lo que se quiere, no por el nombre',
    explica: 'Escribe lo que quieres lograr con tus palabras y ensena los productos cuyas resenas hablan de eso, cada uno con la resena que lo explica. Al lado, lo que da la busqueda por nombre con la misma frase. Es lo que sale arriba en /buscar cuando escribes una frase. Solo lee.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'texto', etiqueta: 'Que quieres lograr', tipo: 'texto', patron: '^[A-Za-z0-9 ]{3,80}$', defecto: 'algo que me ayude a dormir mejor' },
    ],
    construir: (v) => ['-Parte', 'intencion', '-Texto', v.texto],
  },
  {
    id: 'buscar-hibrida', grupo: 'Demos de resenas', titulo: 'Buscador que entiende nombres y frases',
    explica: 'La busqueda hibrida, la lista de /buscar: cada producto con su lugar en la busqueda por palabras y en la de significado, combinados por posicion. labtop gamer sale por las palabras aunque este mal escrito, y una frase sale por el significado. Al lado, la misma busqueda solo por palabras y el tal vez quisiste decir. Solo lee.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'texto', etiqueta: 'Que buscar', tipo: 'texto', patron: '^[A-Za-z0-9 ]{2,80}$', defecto: 'labtop gamer' },
    ],
    construir: (v) => ['-Parte', 'hibrida', '-Texto', v.texto],
  },
  {
    id: 'proponer-sugerencias', grupo: 'Demos de resenas', titulo: 'Sugerencias al proponer un producto',
    explica: 'Lo que ve un vendedor al escribir el nombre de un producto que quiere proponer: en que categoria suele ir y que productos parecidos ya hay, marcando los que pueden ser el mismo. No crea nada.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [
      { nombre: 'texto', etiqueta: 'Nombre del producto', tipo: 'texto', patron: '^[A-Za-z0-9 ]{3,80}$', defecto: 'Laptop ligera para estudiantes' },
    ],
    construir: (v) => ['-Parte', 'sugerencias', '-Texto', v.texto],
  },
  {
    id: 'resenas-clasificador', grupo: 'Demos de resenas', titulo: 'Lo que lee el clasificador de resenas',
    explica: 'Cuantas resenas leyo el clasificador como malas, buenas, dudosas o muy cortas, algunas cuyas estrellas contradicen lo que dice el texto, y cuantas senales de notas incoherentes hay por cuenta, vendedor y producto. Solo lee.',
    script: 'demo-entrega-final.ps1', confirmar: null,
    campos: [],
    construir: () => ['-Parte', 'clasificador'],
  },
  {
    id: 'resenas-texto', grupo: 'Demos de resenas', titulo: 'Resenas copiadas, incoherentes y canceladas',
    explica: 'Cuentas nuevas que compran y resenan de verdad. copiadas: seis cuentas le dejan casi la misma resena a un vendedor nuevo (Vendedor con resenas copiadas y Varias cuentas, la misma resena). incoherentes: una cuenta pone 5 estrellas a cinco productos con textos que dicen que todo salio mal (Sus estrellas contradicen sus textos, y la del vendedor). cancelada: una cuenta pone 5 estrellas y cancela la compra (Resena buena y compra cancelada). negativas: cinco cuentas ponen 1 o 2 estrellas al mismo vendedor y cancelan (Resenas malas y compras canceladas, el vendedor como victima). Cada senal sale sola en unos segundos y la demo dice cuanto tardo. Tarda uno o dos minutos.',
    script: 'demo-resenas-texto.ps1', confirmar: 'SI',
    peligro: 'Deja cuentas, pedidos y movimientos de inventario reales. No hay como deshacerlo.',
    campos: [
      { nombre: 'caso', etiqueta: 'Caso', tipo: 'opcion', opciones: ['todos', 'copiadas', 'incoherentes', 'cancelada', 'negativas'], defecto: 'todos' },
    ],
    construir: (v) => ['-Caso', v.caso],
  },
];

// ---------------------------------------------------------------------------
// Validacion y armado del comando
// ---------------------------------------------------------------------------

class ErrorDeUso extends Error {}

function validarCampo(campo, crudo) {
  const vacio = crudo === undefined || crudo === null || String(crudo).trim() === '';
  if (vacio) {
    if (campo.opcional) return '';
    throw new ErrorDeUso(`Falta ${campo.etiqueta}`);
  }
  const valor = String(crudo).trim();
  if (campo.tipo === 'entero') {
    if (!/^\d{1,10}$/.test(valor)) throw new ErrorDeUso(`${campo.etiqueta} tiene que ser un numero`);
    const n = Number(valor);
    if (n < campo.min || n > campo.max) throw new ErrorDeUso(`${campo.etiqueta} va de ${campo.min} a ${campo.max}`);
    return String(n);
  }
  if (campo.tipo === 'opcion') {
    if (!campo.opciones.includes(valor)) throw new ErrorDeUso(`${campo.etiqueta} no es una opcion valida`);
    return valor;
  }
  if (campo.tipo === 'multiple') {
    // Varias opciones separadas por coma ("sg,de,jp"): cada una tiene que estar en la lista
    const partes = [...new Set(valor.split(',').map((x) => x.trim()).filter(Boolean))];
    if (partes.length === 0) throw new ErrorDeUso(`Elige al menos una opcion en ${campo.etiqueta}`);
    for (const p of partes) {
      if (!campo.opciones.includes(p)) throw new ErrorDeUso(`${campo.etiqueta} trae una opcion que no existe`);
    }
    return partes.join(',');
  }
  if (campo.tipo === 'texto') {
    if (!new RegExp(campo.patron).test(valor)) throw new ErrorDeUso(`${campo.etiqueta} no tiene el formato esperado`);
    return valor;
  }
  throw new ErrorDeUso('Tipo de campo desconocido');
}

// El modo remoto (remoto/README.md): con backend/.env apuntando a otra PC (las bases
// en la de Jose David, por Tailscale) no hay contenedores aqui y el docker de verdad
// no sirve. Los comandos corren con el modo remoto puesto (remoto/activar.ps1, que
// levanta el tunel y pone el docker falso) y se quita al terminar. Asi corren
// tambien arrancar.ps1 y lo que siembra o rehace productos y el grafo (desde el
// 2026-10-20, el docker falso hace sus docker exec contra las bases de alla), y las
// demos de otro pais: el docker falso le pasa sus Tor al Docker de esta PC. Se
// niegan solo los que borran volumenes de Docker (rehacer MongoDB, borrar todo):
// eso se hace en la PC que tiene las bases.
const SOLO_CON_BASES_AQUI = new Set(['reiniciar-mongo', 'reiniciar-todo']);
// Los que no tocan ninguna base: corren igual que siempre.
const SIN_BASES = new Set(['estado', 'backend', 'frontend', 'parar-backend', 'parar-frontend', 'publicar', 'despublicar',
  // Los de caidas hablan con remoto/interruptor.cjs, aqui, y no con las bases.
  'caida-preparar', 'caida-apagar', 'caida-prender', 'caida-estado', 'caida-quitar']);

/** La PC de las bases si backend/.env apunta a otra, o null si son las de aqui. */
function basesRemotas() {
  let host = 'localhost';
  try {
    const m = readFileSync(path.join(RAIZ, 'backend', '.env'), 'utf8').match(/^DB_HOST=(.*)$/m);
    if (m) host = m[1].trim();
  } catch { return null; }
  if (['', 'localhost', '127.0.0.1', '::1'].includes(host)) return null;
  // Va dentro de un comando de PowerShell: solo una IP o un nombre simple.
  if (!/^[A-Za-z0-9.-]+$/.test(host)) throw new ErrorDeUso('backend/.env tiene un DB_HOST que no entiendo');
  return host;
}

/** Devuelve { comando, script, args } o lanza ErrorDeUso. Nada se interpreta con shell. */
function armar(id, valoresCrudos) {
  const c = CATALOGO.find((x) => x.id === id);
  if (!c) throw new ErrorDeUso('Ese comando no existe');
  const v = {};
  for (const campo of c.campos) v[campo.nombre] = validarCampo(campo, valoresCrudos?.[campo.nombre]);
  const args = c.construir(v).map(String);
  const ruta = c.script.replaceAll('/', '\\');
  // Los valores ya pasaron por un patron cerrado, asi que las comillas simples bastan.
  const texto = args.map((a) => (/^-[A-Za-z]+$/.test(a) ? a : `'${a.replaceAll("'", "''")}'`)).join(' ');
  const remota = basesRemotas();
  if (remota && SOLO_CON_BASES_AQUI.has(c.id)) {
    throw new ErrorDeUso(`Las bases estan en otra PC (${remota}). Esto se hace alla, o vuelve a las de aqui con .\\usar-bases-remotas.ps1 -Local`);
  }
  const llamada = `& '.\\${ruta}' ${texto}`;
  // Con las bases en otra PC: el modo remoto antes, y quitarlo siempre al final,
  // tambien si el comando falla o se cancela (el tunel tiene los puertos).
  const cuerpo = remota && !SIN_BASES.has(c.id)
    ? `. '.\\remoto\\activar.ps1' -Ip '${remota}'; if (-not $env:MESH_REMOTO) { exit 1 }; $codigo = 1; try { ${llamada}; $codigo = $LASTEXITCODE } finally { . '.\\remoto\\desactivar.ps1' }; exit $codigo`
    : `${llamada}; exit $LASTEXITCODE`;
  return {
    c,
    // Lo que se muestra y se copia, tal como se escribiria en la terminal
    comando: `.\\${ruta}${texto ? ' ' + texto.replaceAll("'", '') : ''}`,
    // Lo que se ejecuta. UTF-8 para que las tildes de los scripts lleguen bien
    ps: `[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8; ${cuerpo}`,
  };
}

// ---------------------------------------------------------------------------
// El trabajo en curso. Uno a la vez: arrancar.ps1, docker y las demos no se
// llevan bien corriendo juntos, y dos salidas mezcladas no se entienden.
// ---------------------------------------------------------------------------

let trabajo = null;
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]/g;

// Marca de "hay un comando corriendo". Apagar este servidor a mitad de un comando
// lo mata (el comando escribe a un pipe que ya no existe) y deja las bases a medias:
// paso con la demo de otro pais, que habia parado ClickHouse, Neo4j y el backend.
// panel-comandos.ps1 -Parar mira este archivo y se niega si el proceso sigue vivo.
const MARCA = path.join(tmpdir(), 'mesh-logs', 'panel-trabajo.json');
function ponerMarca(t) {
  try {
    mkdirSync(path.dirname(MARCA), { recursive: true });
    writeFileSync(MARCA, JSON.stringify({ pid: t.proc.pid, titulo: t.titulo, inicio: t.inicio }));
  } catch { /* la marca es una ayuda, no debe tumbar el comando */ }
}
function quitarMarca() {
  try { rmSync(MARCA, { force: true }); } catch { /* idem */ }
}

function lanzar(armado) {
  const t = {
    id: randomBytes(4).toString('hex'),
    titulo: armado.c.titulo,
    comando: armado.comando,
    estado: 'corriendo',
    codigo: null,
    inicio: Date.now(),
    fin: null,
    lineas: [],
    proc: null,
  };
  const proc = spawn(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', armado.ps],
    { cwd: RAIZ, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  t.proc = proc;

  const vaciadores = [];
  const juntar = (flujo) => {
    const dec = new StringDecoder('utf8');
    let resto = '';
    flujo.on('data', (buf) => {
      resto += dec.write(buf);
      const partes = resto.split(/\r?\n/);
      resto = partes.pop();
      for (const l of partes) t.lineas.push(l.replace(ANSI, ''));
    });
    // Suelta la ultima linea si no termino en salto. Se llama al cerrar el flujo o,
    // si no cierra nunca (ver 'exit' abajo), cuando el comando ya termino.
    let vaciado = false;
    const vaciar = () => {
      if (vaciado) return;
      vaciado = true;
      resto += dec.end();
      if (resto) t.lineas.push(resto.replace(ANSI, ''));
      resto = '';
    };
    flujo.on('end', vaciar);
    vaciadores.push(vaciar);
  };
  juntar(proc.stdout);
  juntar(proc.stderr);

  proc.on('error', (e) => {
    t.lineas.push(`No se pudo lanzar PowerShell, ${e.message}`);
    t.estado = 'fallo';
    t.fin = Date.now();
    quitarMarca();
  });
  // Se da por terminado cuando el PROCESO sale ('exit'), no cuando se cierran sus
  // pipes ('close'). Un comando que deja un proceso vivo detras (la demo de otro pais
  // relanzaba el backend con `npm run start`; "Levantar todo" hace lo mismo) le pasa
  // los pipes al hijo, y 'close' no llega hasta que ese hijo muere: el panel se
  // quedaba en "corriendo" para siempre, con todos los botones apagados y sin dejar
  // apagar el panel. Se espera un momento para leer lo ultimo que escribio.
  proc.on('exit', (codigo) => {
    setTimeout(() => {
      for (const v of vaciadores) v();
      t.codigo = codigo;
      if (t.estado === 'corriendo') t.estado = codigo === 0 ? 'ok' : 'fallo';
      t.fin = Date.now();
      quitarMarca();
      // Soltar los pipes: el hijo que sigue vivo ya no tiene a quien escribirle
      proc.stdout.destroy();
      proc.stderr.destroy();
    }, 400);
  });
  ponerMarca(t);
  trabajo = t;
  return t;
}

function parar() {
  if (!trabajo || trabajo.estado !== 'corriendo') return false;
  trabajo.estado = 'parado';
  trabajo.lineas.push('--- Parado desde el panel ---');
  spawn('taskkill', ['/PID', String(trabajo.proc.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
  return true;
}

// ---------------------------------------------------------------------------
// Estado de los servicios, sin ejecutar nada: solo se prueba si el puerto abre
// ---------------------------------------------------------------------------

function puertoAbierto(puerto, host = 'localhost') {
  return new Promise((resolver) => {
    // 'localhost' y no 127.0.0.1: vite preview escucha solo en IPv6 ([::1]) y con
    // 127.0.0.1 la tienda salia apagada estando arriba. Una base en otra PC va por
    // Tailscale: mas plazo.
    const s = net.connect({ port: puerto, host, timeout: host === 'localhost' ? 800 : 3000 });
    s.on('connect', () => { s.destroy(); resolver(true); });
    s.on('timeout', () => { s.destroy(); resolver(false); });
    s.on('error', () => resolver(false));
  });
}

const SERVICIOS_VIGILADOS = [
  { nombre: 'Backend', puerto: 3000 },
  { nombre: 'Tienda', puerto: 5173 },
  { nombre: 'PostgreSQL', puerto: 5432, base: true },
  { nombre: 'MongoDB', puerto: 27018, base: true },
  { nombre: 'Redis', puerto: 6379, base: true },
  { nombre: 'Neo4j', puerto: 7687, base: true },
  { nombre: 'ClickHouse', puerto: 8123, base: true },
  { nombre: 'Elasticsearch', puerto: 9200, base: true },
];

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

const HOSTS_OK = new Set([`127.0.0.1:${PUERTO}`, `localhost:${PUERTO}`]);
const ORIGENES_OK = new Set([`http://127.0.0.1:${PUERTO}`, `http://localhost:${PUERTO}`, ...FRONTENDS_OK]);

// El frontend de Mesh (pestana Comandos del panel) le habla a este servidor
// directamente desde el navegador, asi que es el UNICO origen al que se le
// concede CORS y al que se le entrega el token (GET /api/token). Otra pagina,
// aunque este abierta en la misma maquina, recibe 403 y ademas el navegador no le
// deja leer la respuesta. El navegador no permite falsificar la cabecera Origin.
//
// Antes esa pestana era un iframe a esta misma pagina, para que el token no saliera
// de aqui. Se cambio porque un iframe no hereda el tema, ni el tamano, ni las
// fuentes de Mesh, y se veia como un cuerpo extrano. El costo es que un XSS en
// Mesh podria pedir el token; Mesh no usa {@html} en ningun sitio, y lo destructivo
// sigue pidiendo confirmacion aqui en el servidor.
// (FRONTENDS_OK esta declarada arriba, junto a las otras constantes.)

function responder(res, estado, cuerpo, tipo = 'application/json; charset=utf-8') {
  res.writeHead(estado, {
    'Content-Type': tipo,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    // Esta pagina propia no debe poder enmarcarse en ningun sitio.
    'Content-Security-Policy': "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'",
  });
  res.end(typeof cuerpo === 'string' ? cuerpo : JSON.stringify(cuerpo));
}

function leerJson(req) {
  return new Promise((resolver, rechazar) => {
    let n = 0;
    const partes = [];
    req.on('data', (b) => {
      n += b.length;
      if (n > 16_000) { rechazar(new ErrorDeUso('Cuerpo demasiado grande')); req.destroy(); return; }
      partes.push(b);
    });
    req.on('end', () => {
      try { resolver(partes.length ? JSON.parse(Buffer.concat(partes).toString('utf8')) : {}); }
      catch { rechazar(new ErrorDeUso('JSON invalido')); }
    });
  });
}

const servidor = http.createServer(async (req, res) => {
  try {
    if (!HOSTS_OK.has(req.headers.host ?? '')) return responder(res, 403, { error: 'Host no permitido' });
    const url = new URL(req.url, `http://${req.headers.host}`);

    // CORS: solo para el frontend de Mesh. Cualquier otro origen no recibe estas
    // cabeceras y el navegador le oculta la respuesta.
    const origen = req.headers.origin;
    if (origen && FRONTENDS_OK.includes(origen)) {
      res.setHeader('Access-Control-Allow-Origin', origen);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Headers', 'x-token, content-type');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Max-Age', '600');
    }
    if (req.method === 'OPTIONS') {
      // Preflight: se contesta sin cuerpo, y solo a quien tiene permiso.
      res.writeHead(origen && FRONTENDS_OK.includes(origen) ? 204 : 403);
      return res.end();
    }

    if (req.method === 'GET' && url.pathname === '/api/token') {
      // Solo el frontend de Mesh puede pedirlo. Sin cabecera Origin (curl, un
      // script) tampoco: no hay nada que comprobar y no se entrega.
      if (!origen || !FRONTENDS_OK.includes(origen)) return responder(res, 403, { error: 'Origen no permitido' });
      return responder(res, 200, { token: TOKEN });
    }

    if (req.method === 'GET' && url.pathname === '/') {
      const html = readFileSync(path.join(AQUI, 'index.html'), 'utf8').replace('__TOKEN__', TOKEN);
      return responder(res, 200, html, 'text/html; charset=utf-8');
    }

    if (!url.pathname.startsWith('/api/')) return responder(res, 404, { error: 'No existe' });
    if (req.headers['x-token'] !== TOKEN) return responder(res, 401, { error: 'Falta el token, recarga la pagina' });
    if (origen && !ORIGENES_OK.has(origen)) return responder(res, 403, { error: 'Origen no permitido' });

    if (req.method === 'GET' && url.pathname === '/api/catalogo') {
      return responder(res, 200, CATALOGO.map(({ construir, script, ...publico }) => publico));
    }

    if (req.method === 'GET' && url.pathname === '/api/estado') {
      // Las bases se prueban donde estan: aqui, o en la PC de backend/.env (modo remoto).
      let remota = null;
      try { remota = basesRemotas(); } catch { /* un DB_HOST raro: se prueban aqui */ }
      const estados = await Promise.all(SERVICIOS_VIGILADOS.map(async (s) => ({
        ...s, arriba: await puertoAbierto(s.puerto, s.base && remota ? remota : 'localhost'),
      })));
      return responder(res, 200, estados);
    }

    if (req.method === 'GET' && url.pathname === '/api/trabajo') {
      if (!trabajo) return responder(res, 200, { hay: false });
      const desde = Math.max(0, Number(url.searchParams.get('desde')) || 0);
      return responder(res, 200, {
        hay: true, id: trabajo.id, titulo: trabajo.titulo, comando: trabajo.comando,
        estado: trabajo.estado, codigo: trabajo.codigo,
        segundos: Math.round(((trabajo.fin ?? Date.now()) - trabajo.inicio) / 1000),
        lineas: trabajo.lineas.slice(desde), siguiente: trabajo.lineas.length,
      });
    }

    if (req.method === 'POST' && url.pathname === '/api/vista') {
      const b = await leerJson(req);
      return responder(res, 200, { comando: armar(b.id, b.valores).comando });
    }

    if (req.method === 'POST' && url.pathname === '/api/ejecutar') {
      const b = await leerJson(req);
      const armado = armar(b.id, b.valores);
      if (armado.c.confirmar && b.confirmacion !== armado.c.confirmar) {
        throw new ErrorDeUso('Falta la confirmacion');
      }
      if (trabajo && trabajo.estado === 'corriendo') {
        return responder(res, 409, { error: `Ya hay algo corriendo, ${trabajo.titulo}. Espera o pulsa Parar.` });
      }
      const t = lanzar(armado);
      return responder(res, 200, { id: t.id });
    }

    if (req.method === 'POST' && url.pathname === '/api/parar') {
      return responder(res, 200, { parado: parar() });
    }

    return responder(res, 404, { error: 'No existe' });
  } catch (e) {
    if (e instanceof ErrorDeUso) return responder(res, 400, { error: e.message });
    console.error(e);
    return responder(res, 500, { error: 'Error interno del panel' });
  }
});

servidor.on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `El puerto ${PUERTO} ya esta ocupado. Probablemente el panel ya esta corriendo.` : e.message);
  process.exit(1);
});
servidor.listen(PUERTO, '127.0.0.1', () => console.log(`Panel de comandos en http://127.0.0.1:${PUERTO}`));
