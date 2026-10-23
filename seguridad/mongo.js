// seguridad/mongo.js
// Los usuarios de cada servicio en MongoDB. Lo corre arrancar.ps1 con mongosh,
// como el usuario root, en cada arranque. Las contrasenas llegan por variables
// de entorno (CLAVE_BACKEND, CLAVE_LECTURA) y la base por MONGO_DB, desde el
// .env; nunca quedan escritas en el repositorio.
//
//   mesh_backend   el backend. Con el rol mesh_backend_rol, hecho a medida:
//                  buscar, insertar, cambiar y borrar documentos de la base de
//                  la tienda, y nada mas. No crea ni borra colecciones ni
//                  indices, no ve otras bases y no administra usuarios.
//                  readWrite, el rol de fabrica, si deja borrar colecciones e
//                  indices, y el backend no lo necesita nunca.
//   mesh_lectura   DbGate, la ventana de MongoDB. El rol read de fabrica, solo
//                  sobre la base de la tienda.
//
// El root (MONGO_USER del .env) queda para arrancar.ps1, el ETL y las pruebas.
//
// Los usuarios viven en la base admin, como el root, para que el backend siga
// entrando con authSource=admin.
//
// Se puede correr cuantas veces sea: crea lo que falta y vuelve a poner las
// contrasenas y los permisos.

const base = process.env.MONGO_DB;
const claveBackend = process.env.CLAVE_BACKEND;
const claveLectura = process.env.CLAVE_LECTURA;
if (!base || !claveBackend || !claveLectura) {
  print('Faltan MONGO_DB, CLAVE_BACKEND o CLAVE_LECTURA');
  quit(1);
}

const admin = db.getSiblingDB('admin');

const privilegiosBackend = [
  {
    resource: { db: base, collection: '' },
    actions: ['find', 'insert', 'update', 'remove'],
  },
];

if (admin.getRole('mesh_backend_rol')) {
  admin.updateRole('mesh_backend_rol', { privileges: privilegiosBackend, roles: [] });
} else {
  admin.createRole({ role: 'mesh_backend_rol', privileges: privilegiosBackend, roles: [] });
}

function usuario(nombre, clave, roles) {
  if (admin.getUser(nombre)) {
    admin.updateUser(nombre, { pwd: clave, roles });
    print(`${nombre} al dia`);
  } else {
    admin.createUser({ user: nombre, pwd: clave, roles });
    print(`${nombre} creado`);
  }
}

usuario('mesh_backend', claveBackend, [{ role: 'mesh_backend_rol', db: 'admin' }]);
usuario('mesh_lectura', claveLectura, [{ role: 'read', db: base }]);

const acciones = admin.getRole('mesh_backend_rol', { showPrivileges: true })
  .privileges.map((p) => p.actions.join(', '));
print(`mesh_backend_rol puede: ${acciones.join(' | ')} en ${base}`);
