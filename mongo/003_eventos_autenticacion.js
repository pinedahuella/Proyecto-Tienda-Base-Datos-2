// 003_eventos_autenticacion.js
// La coleccion del log de autenticacion y sus indices.
//
// eventos_autenticacion
//   Un documento por cada intento de entrar: login (bueno o malo), logout y
//   registro. La escribe LogService del backend desde el 2026-09-10; antes
//   ese log eran las tablas log_login y log_registro de PostgreSQL, que siguen
//   ahi pero ya no reciben filas (ver migrations/016_alerta_fraude.sql).
//
//   Solo se inserta, nunca se edita. La unica escritura despues del insert es
//   la del worker que lo copia a Elasticsearch, que le quita la bandera
//   pendiente_elastic. La forma del documento esta en
//   backend/src/models/evento-autenticacion.ts:
//
//     tipo                     login | logout | registro
//     resultado                exito | fallo
//     motivo                   por que fallo, null si salio bien
//     id_usuario               texto, null si no se puede atribuir
//     identificador_intentado  el correo o usuario tecleado, tal cual
//     ip                       texto, null si no se supo
//     user_agent, huella_cliente
//     fecha                    Date, la pone el backend
//     pendiente_elastic        true hasta que el worker lo copia; despues no esta
//
// Es la coleccion que MAS se escribe del proyecto: un insert por cada intento
// de entrar, y un ataque de fuerza bruta son cientos por minuto. Eso importa
// para los indices de abajo, porque cada indice se paga en cada insert.
//
// Todo es idempotente, porque arrancar.ps1 corre TODOS los .js de mongo/ en
// cada arranque, y nada lanza: si uno sale con codigo distinto de 0 se cae el
// arranque entero, y un indice que falta es un problema de rendimiento, no un
// motivo para no levantar. Lo que falle sale con un OJO delante, igual que en
// 002_resenas.js.


// ============================================================
// La coleccion
// ============================================================
// Puede que ya exista aunque este archivo nunca haya corrido: el backend la
// crea solo con su primer insert. createCollection revienta si ya esta, asi
// que se pregunta primero.
const COLECCION = 'eventos_autenticacion';

try {
    if (db.getCollectionNames().indexOf(COLECCION) === -1) {
        db.createCollection(COLECCION);
        print(COLECCION + ' creada');
    } else {
        print(COLECCION + ' ya existia');
    }
} catch (e) {
    print('OJO: no se pudo crear ' + COLECCION + ': ' + e.message);
}


// ============================================================
// Los indices
// ============================================================
// Seis, en dos grupos que no se parecen.
//
// EL PARCIAL, eventos_pendientes_elastic, es el unico que hoy sirve a una
// consulta que corre de verdad. EventosAutenticacionSyncService pregunta cada
// 5 segundos
//
//   find({ pendiente_elastic: true }).sort({ fecha: 1 }).limit(500)
//
// y sin indice eso es recorrer la coleccion ENTERA cada 5 segundos para
// encontrar, casi siempre, ninguno. La coleccion solo crece.
//
// Es PARCIAL por lo mismo que idx_evento_grafo_cola en la 015: solo guarda
// los documentos que tienen pendiente_elastic: true. En cuanto el worker le
// quita la bandera, el documento sale del indice. Asi el indice tiene el
// tamano de la cola, que casi siempre es cero, y no el del historico entero.
//
// La clave es fecha y NO pendiente_elastic, que es lo que uno pondria a
// primera vista. Dentro de este indice todos los documentos valen true, asi
// que esa clave no separaria nada; fecha si sirve, porque es el orden que pide
// el worker, y asi el explain sale sin etapa SORT. Mongo lo puede usar porque
// el filtro de la consulta ({ pendiente_elastic: true }) implica el del
// indice; con otra consulta, por ejemplo $exists, no lo tocaria.
//
// LOS OTROS CINCO son los que pide el plan del modulo de fraude
// (backend/elementos Generales/plan pendiente/fraude-login-eventos.md). Cada
// uno contesta "que paso con ESTO en este rango de fechas", con la igualdad
// primero y la fecha detras, descendente, para sacar lo mas reciente sin
// ordenar en memoria:
//
//   eventos_por_usuario         la historia de una cuenta
//   eventos_por_ip              todo lo que salio de una IP (fuerza bruta)
//   eventos_por_tipo_resultado  los fallos de login de un rango de fechas
//   eventos_por_identificador   los intentos contra un correo, exista o no
//   eventos_por_huella          varias cuentas desde el mismo navegador
//
// Hay que decirlo claro: HOY ninguna ruta del backend hace esas consultas
// contra Mongo. Las agregaciones del panel van contra Elasticsearch, y los
// contadores del login contra Redis. Estos cinco sirven para investigar un
// incidente desde mongosh, y para quien lea esta coleccion en bloque (el ETL
// de ClickHouse, cuando se repunte desde log_login). En una coleccion que se
// escribe tanto, un indice que nadie usa se paga en cada insert; si pasado un
// tiempo $indexStats dice que alguno no se toca, se quita.
const INDICES = [
    { nombre: 'eventos_pendientes_elastic',
      clave: { fecha: 1 },
      opciones: { partialFilterExpression: { pendiente_elastic: true } } },
    { nombre: 'eventos_por_usuario',
      clave: { id_usuario: 1, fecha: -1 } },
    { nombre: 'eventos_por_ip',
      clave: { ip: 1, fecha: -1 } },
    { nombre: 'eventos_por_tipo_resultado',
      clave: { tipo: 1, resultado: 1, fecha: -1 } },
    { nombre: 'eventos_por_identificador',
      clave: { identificador_intentado: 1, fecha: -1 } },
    { nombre: 'eventos_por_huella',
      clave: { huella_cliente: 1, fecha: -1 } }
];

// Se pregunta antes de crear, por nombre, igual que 002_resenas.js: para
// poder decir si se creo o si ya estaba, y para no pisar un indice que alguien
// puso a mano con el mismo nombre y otras claves. Crearlo encima daria
// IndexKeySpecsConflict; borrarlo por las buenas seria peor. Se avisa y se
// sigue.
//
// En el parcial se compara tambien el filtro, porque un {fecha: 1} SIN filtro
// con ese nombre seria un indice sobre toda la coleccion: funcionaria, y
// creceria con el historico entero sin que nada lo dijera.
const creados = [];
const yaEstaban = [];

INDICES.forEach(function (ind) {
    try {
        const existente = db.getCollection(COLECCION).getIndexes().filter(function (i) {
            return i.name === ind.nombre;
        })[0];

        const filtroEsperado = ind.opciones ? ind.opciones.partialFilterExpression : undefined;

        if (!existente) {
            const opciones = Object.assign({ name: ind.nombre }, ind.opciones || {});
            db.getCollection(COLECCION).createIndex(ind.clave, opciones);
            creados.push(ind.nombre);
        } else if (JSON.stringify(existente.key) !== JSON.stringify(ind.clave)
                || JSON.stringify(existente.partialFilterExpression) !== JSON.stringify(filtroEsperado)) {
            print('OJO: ' + ind.nombre + ' ya existe con otra definicion '
                + JSON.stringify(existente.key)
                + (existente.partialFilterExpression
                    ? ' filtro ' + JSON.stringify(existente.partialFilterExpression) : ' sin filtro')
                + ', se dejo como estaba');
        } else {
            yaEstaban.push(ind.nombre);
        }
    } catch (e) {
        print('OJO: no se pudo crear el indice ' + ind.nombre + ': ' + e.message);
    }
});

print('indices de ' + COLECCION + ': '
    + creados.length + ' creados, ' + yaEstaban.length + ' ya estaban');
