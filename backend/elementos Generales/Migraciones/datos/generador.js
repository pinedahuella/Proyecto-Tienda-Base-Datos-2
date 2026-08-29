// generador.js
// Escribe migrations/datos/001_catalogo.sql.
//
//   node migrations/datos/generador.js
//
// Por que un generador y no SQL a mano: el CONTENIDO (que categorias existen,
// como se llaman los productos, que caracteristicas ofrece cada hoja) se
// escribe aqui a mano, porque eso es criterio. El REPARTO (que vendedor oferta
// que variante, con cuanto stock y a que precio) es mecanico, y lo mecanico no
// se escribe a mano: se calcula.
//
// Es determinista a proposito. El azar sale de una semilla fija, asi que
// correrlo dos veces da el mismo archivo. Sin eso, cada corrida cambiaria el
// conjunto de datos y nadie podria comparar dos bases.
//
// El SQL que sale NO lleva un solo id a mano: todo se busca por nombre o por
// correo. Es la regla de migrations/README.md, y viene de que un id escrito a
// mano corre en una maquina y revienta en la de al lado.

const fs = require('fs');
const path = require('path');

// ============================================================
// El azar, con semilla
// ============================================================
// mulberry32. Lo que importa no es que sea buen azar: es que sea EL MISMO
// azar siempre.
function crearAzar(semilla) {
  let a = semilla >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const azar = crearAzar(20260825);
const entre = (min, max) => min + Math.floor(azar() * (max - min + 1));


// ============================================================
// Las cuentas
// ============================================================
// La primera es la tienda: tiene oferta de TODO el catalogo y su precio es el
// que se ensena en la pagina. Lo pidio el profesor, y de paso quita el caso
// incomodo de un producto sin ningun precio que mostrar.
//
// Los hashes son scrypt en formato salt:hash, los mismos que genera
// backend/src/helpers/contrasena.ts. Estan en el repositorio a proposito: son
// cuentas de prueba y no dan acceso a nada real. El salt es fijo para que el
// generador escriba siempre el mismo archivo.
const CLAVE_VENDEDOR = '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5';
const CLAVE_COMPRADOR = '9f8e7d6c5b4a39281706f5e4d3c2b1a0:d3af92a164ee8d7608de4ccb96f35d5295245949d9eefffe9dbe892d2cad0cad2fb0c921d6c561264f3a0895242d86893173d1aa9235f77703ef61c86eb13d35';
const CLAVE_ADMIN = '0011223344556677889aabbccddeeff0:ac37be7b7ff5172d000f7f0c844ae57eee77959dc4614ba59ec74aba548099fd03e01a3c47daa403da682c9ff95465d8b8b9bc401acb94fceab6f5794ba7328a';

const TIENDA = {
  correo: 'tienda@mesh.com', usuario: 'mesh_tienda',
  nombre: 'Mesh', apellido: 'Tienda', rol: 'vendedor', clave: CLAVE_VENDEDOR,
};

const VENDEDORES = [
  { correo: 'ventas.norte@mesh.com',    usuario: 'ventas_norte',    nombre: 'Carlos', apellido: 'Ramirez',  rol: 'vendedor', clave: CLAVE_VENDEDOR },
  { correo: 'ventas.sur@mesh.com',      usuario: 'ventas_sur',      nombre: 'Lucia',  apellido: 'Morales',  rol: 'vendedor', clave: CLAVE_VENDEDOR },
  { correo: 'ventas.oriente@mesh.com',  usuario: 'ventas_oriente',  nombre: 'Andres', apellido: 'Castillo', rol: 'vendedor', clave: CLAVE_VENDEDOR },
  { correo: 'ventas.poniente@mesh.com', usuario: 'ventas_poniente', nombre: 'Paola',  apellido: 'Guzman',   rol: 'vendedor', clave: CLAVE_VENDEDOR },
];

const COMPRADORES = [
  { correo: 'compradora.norte@mesh.com', usuario: 'compradora_norte', nombre: 'Ana',    apellido: 'Lopez',   rol: 'comprador', clave: CLAVE_COMPRADOR },
  { correo: 'comprador.sur@mesh.com',    usuario: 'comprador_sur',    nombre: 'Miguel', apellido: 'Herrera', rol: 'comprador', clave: CLAVE_COMPRADOR },
];

const ADMIN = {
  correo: 'admin@mesh.com', usuario: 'admin_mesh',
  nombre: 'Sofia', apellido: 'Vega', rol: 'admin', clave: CLAVE_ADMIN,
};

const USUARIOS = [TIENDA, ...VENDEDORES, ...COMPRADORES, ADMIN];


// ============================================================
// Las definiciones de caracteristica
// ============================================================
// Se definen una vez y las usan muchas categorias. La unidad va aqui y no en
// cada valor: que la RAM se mide en GB se dice una sola vez, y asi el valor
// queda limpio (16 y no "16 GB") y se puede comparar como numero.
const CARACTERISTICAS = [
  ['Marca',                    'texto'],
  ['Modelo',                   'texto'],
  ['Pais de origen',           'texto'],
  ['Garantia',                 'entero',   'meses'],
  ['Material principal',       'texto'],
  ['Peso',                     'decimal',  'kg'],
  ['Potencia',                 'entero',   'W'],
  ['Duracion de la bateria',   'decimal',  'h'],
  ['Inalambrico',              'booleano'],
  ['Impermeable',              'booleano'],
  ['Requiere ensamblaje',      'booleano'],
  ['Apto para lavavajillas',   'booleano'],
  ['Contenido del paquete',    'lista'],
  ['Certificaciones',          'lista'],
  ['Autor',                    'texto'],
  ['Editorial',                'texto'],
  ['Paginas',                  'entero',   'paginas'],
  ['Idioma',                   'texto'],
  ['Anio de publicacion',      'entero'],
  ['Tipo de piel',             'texto'],
  ['Ingredientes destacados',  'lista'],
  ['Tipo de fragancia',        'texto'],
  ['Nivel de resistencia',     'texto'],
  ['Origen del algodon',       'texto'],
];

const CARACTERISTICAS_VARIANTE = [
  ['Color',               'texto'],
  ['Talla',               'texto'],
  ['Numero de calzado',   'entero'],
  ['Memoria RAM',         'entero',  'GB'],
  ['Almacenamiento',      'entero',  'GB'],
  ['Tamano de pantalla',  'decimal', 'pulgadas'],
  ['Tasa de refresco',    'entero',  'Hz'],
  ['Capacidad',           'decimal', 'L'],
  ['Volumen',             'entero',  'ml'],
  ['Acabado',             'texto'],
  ['Formato',             'texto'],
  ['Longitud del cable',  'decimal', 'm'],
];


// ============================================================
// El catalogo
// ============================================================
// Dos niveles y solo dos: una raiz agrupa y no lleva nada; sus hojas llevan
// las caracteristicas y los productos.
//
// paleta / paletaVariante son lo que OFRECE la categoria, no lo que tiene un
// producto. Estan a proposito mas anchas de lo que se llena: si cada producto
// llenara el 100%, el modelo pareceria una tabla de columnas fijas y
// desapareceria justo el fenomeno que la Entrega 1 tiene que ensenar.
const CATALOGO = [
{ raiz: 'Electronica', hojas: [

  { nombre: 'Laptops',
    paleta: ['Marca','Modelo','Pais de origen','Garantia','Peso','Duracion de la bateria','Contenido del paquete','Certificaciones','Material principal'],
    paletaVariante: ['Memoria RAM','Almacenamiento','Tamano de pantalla','Color','Acabado'],
    productos: [
      { nombre: 'Laptop Aurora 14', precio: 6200,
        descripcion: 'Ultraligera de 14 pulgadas con chasis de aluminio y teclado retroiluminado.',
        car: { Marca:'Aurora', Modelo:'A14-2026', 'Pais de origen':'China', Garantia:24, Peso:1.28, 'Duracion de la bateria':11.5, 'Contenido del paquete':['Laptop','Cargador USB-C','Guia rapida'] },
        variantes: [
          { nombre:'16 GB / 512 GB', factor:1.00, car:{ 'Memoria RAM':16, Almacenamiento:512, 'Tamano de pantalla':14, Color:'Gris grafito' } },
          { nombre:'32 GB / 1 TB', factor:1.42, car:{ 'Memoria RAM':32, Almacenamiento:1024, 'Tamano de pantalla':14, Color:'Gris grafito', Acabado:'Mate' } },
        ] },
      { nombre: 'Laptop Bastion 16', precio: 9400,
        descripcion: 'Estacion de trabajo de 16 pulgadas para render y compilacion.',
        car: { Marca:'Bastion', Modelo:'W16-Pro', Garantia:36, Peso:2.15, 'Duracion de la bateria':7, Certificaciones:['MIL-STD-810H','Energy Star'], 'Material principal':'Aleacion de magnesio' },
        variantes: [
          { nombre:'32 GB / 1 TB', factor:1.00, car:{ 'Memoria RAM':32, Almacenamiento:1024, 'Tamano de pantalla':16, Color:'Negro' } },
          { nombre:'64 GB / 2 TB', factor:1.55, car:{ 'Memoria RAM':64, Almacenamiento:2048, 'Tamano de pantalla':16, Color:'Negro' } },
        ] },
      { nombre: 'Laptop Nimbo 13', precio: 4100,
        descripcion: 'Equipo de entrada para estudio y oficina, silencioso y sin ventilador.',
        car: { Marca:'Nimbo', Modelo:'N13', 'Pais de origen':'Vietnam', Garantia:12, Peso:1.05 },
        variantes: [
          { nombre:'8 GB / 256 GB', factor:1.00, car:{ 'Memoria RAM':8, Almacenamiento:256, 'Tamano de pantalla':13.3, Color:'Plata' } },
        ] },
      { nombre: 'Laptop Lienzo 15', precio: 5400,
        descripcion: 'Convertible de 15.6 pulgadas con bisagra de 360 grados y lapiz optico incluido.',
        car: { Marca:'Lienzo', Modelo:'L15-Flex', 'Pais de origen':'Mexico', Peso:1.62, 'Contenido del paquete':['Laptop','Cargador de 65 W','Lapiz optico'] },
        variantes: [
          { nombre:'16 GB / 512 GB', factor:1.00, car:{ 'Memoria RAM':16, Almacenamiento:512, 'Tamano de pantalla':15.6, Color:'Plata perla' } },
          { nombre:'16 GB / 1 TB', factor:1.19, car:{ 'Memoria RAM':16, Almacenamiento:1024, 'Tamano de pantalla':15.6, Color:'Plata perla' } },
          { nombre:'32 GB / 1 TB', factor:1.46, car:{ 'Memoria RAM':32, Almacenamiento:1024, 'Tamano de pantalla':15.6, Color:'Azul acero', Acabado:'Satinado' } },
        ] },
      { nombre: 'Laptop Cumbre 17 Gamer', precio: 11800,
        descripcion: 'Portatil de 17.3 pulgadas con refrigeracion de doble ventilador y teclado mecanico.',
        car: { Marca:'Cumbre', Garantia:24, Peso:2.68, 'Duracion de la bateria':5.5, 'Material principal':'Aleacion de aluminio', Certificaciones:['Energy Star','RoHS'] },
        variantes: [
          { nombre:'32 GB / 1 TB', factor:1.00, car:{ 'Memoria RAM':32, Almacenamiento:1024, 'Tamano de pantalla':17.3, Color:'Negro obsidiana' } },
          { nombre:'64 GB / 2 TB', factor:1.38, car:{ 'Memoria RAM':64, Almacenamiento:2048, 'Tamano de pantalla':17.3, Color:'Negro obsidiana', Acabado:'Mate' } },
        ] },
      { nombre: 'Laptop Vireo Air 12', precio: 3450,
        descripcion: 'Netbook de 12.5 pulgadas para clases y navegacion, arranca en menos de diez segundos.',
        car: { Marca:'Vireo', Modelo:'Air-12', Garantia:12, 'Duracion de la bateria':14 },
        variantes: [
          { nombre:'8 GB / 128 GB', factor:1.00, car:{ 'Memoria RAM':8, Almacenamiento:128, 'Tamano de pantalla':12.5, Color:'Blanco hueso' } },
        ] },
      { nombre: 'Laptop Ambar Campus 14', precio: 4750,
        descripcion: 'Chasis reforzado con bisagras probadas a diez mil aperturas, pensada para mochila.',
        car: { Marca:'Ambar', 'Pais de origen':'Taiwan', Garantia:18, 'Material principal':'Policarbonato reforzado', 'Contenido del paquete':['Laptop','Cargador','Funda de neopreno'] },
        variantes: [
          { nombre:'8 GB / 256 GB', factor:1.00, car:{ 'Memoria RAM':8, Almacenamiento:256, 'Tamano de pantalla':14, Color:'Gris arena' } },
          { nombre:'16 GB / 512 GB', factor:1.27, car:{ 'Memoria RAM':16, Almacenamiento:512, 'Tamano de pantalla':14, Color:'Gris arena', Acabado:'Texturizado' } },
        ] },
    ] },

  { nombre: 'Telefonos',
    paleta: ['Marca','Modelo','Pais de origen','Garantia','Peso','Impermeable','Contenido del paquete','Duracion de la bateria','Certificaciones'],
    paletaVariante: ['Almacenamiento','Color','Tamano de pantalla','Memoria RAM'],
    productos: [
      { nombre: 'Telefono Vela 7', precio: 5300,
        descripcion: 'Pantalla OLED de 6.4 pulgadas y camara principal de 50 MP.',
        car: { Marca:'Vela', Modelo:'V7', Garantia:12, Peso:0.19, Impermeable:true, 'Contenido del paquete':['Telefono','Cable USB-C','Pin de bandeja'] },
        variantes: [
          { nombre:'128 GB', factor:1.00, car:{ Almacenamiento:128, Color:'Azul medianoche', 'Tamano de pantalla':6.4 } },
          { nombre:'256 GB', factor:1.18, car:{ Almacenamiento:256, Color:'Azul medianoche', 'Tamano de pantalla':6.4 } },
          { nombre:'512 GB', factor:1.36, car:{ Almacenamiento:512, Color:'Grafito', 'Tamano de pantalla':6.4 } },
        ] },
      { nombre: 'Telefono Ceibo Lite', precio: 1850,
        descripcion: 'Bateria de dos dias y ranura para memoria expandible.',
        car: { Marca:'Ceibo', Modelo:'Lite-3', 'Pais de origen':'India', Garantia:12, 'Duracion de la bateria':48 },
        variantes: [
          { nombre:'64 GB', factor:1.00, car:{ Almacenamiento:64, Color:'Verde', 'Tamano de pantalla':6.1 } },
          { nombre:'128 GB', factor:1.22, car:{ Almacenamiento:128, Color:'Negro', 'Tamano de pantalla':6.1 } },
        ] },
      { nombre: 'Telefono Nautilo Pro', precio: 7200,
        descripcion: 'Triple camara con teleobjetivo de tres aumentos y carga completa en treinta minutos.',
        car: { Marca:'Nautilo', Modelo:'NP-9', Garantia:24, Impermeable:true, Certificaciones:['IP68','CE'] },
        variantes: [
          { nombre:'256 GB', factor:1.00, car:{ Almacenamiento:256, 'Memoria RAM':12, Color:'Titanio' } },
          { nombre:'512 GB', factor:1.21, car:{ Almacenamiento:512, 'Memoria RAM':12, Color:'Titanio', 'Tamano de pantalla':6.7 } },
          { nombre:'1 TB', factor:1.48, car:{ Almacenamiento:1024, 'Memoria RAM':16, Color:'Negro volcan' } },
        ] },
      { nombre: 'Telefono Pedernal Rugged', precio: 3900,
        descripcion: 'Carcasa con esquinas reforzadas y bateria de gran capacidad para trabajo de campo.',
        car: { Marca:'Pedernal', Modelo:'R2', 'Pais de origen':'China', Peso:0.28, Impermeable:true, 'Duracion de la bateria':72 },
        variantes: [
          { nombre:'128 GB', factor:1.00, car:{ Almacenamiento:128, Color:'Negro y naranja', 'Tamano de pantalla':6 } },
          { nombre:'256 GB', factor:1.16, car:{ Almacenamiento:256, Color:'Negro y verde', 'Tamano de pantalla':6 } },
        ] },
      { nombre: 'Telefono Bruma Mini', precio: 2600,
        descripcion: 'Cuerpo compacto de 5.8 pulgadas que se maneja con una sola mano.',
        car: { Marca:'Bruma', Garantia:12, Peso:0.16, 'Contenido del paquete':['Telefono','Cable USB-C','Funda transparente'] },
        variantes: [
          { nombre:'128 GB', factor:1.00, car:{ Almacenamiento:128, Color:'Lavanda', 'Tamano de pantalla':5.8 } },
        ] },
      { nombre: 'Telefono Cuarzo Duo', precio: 1450,
        descripcion: 'Doble linea con dos ranuras SIM activas y radio FM sin auriculares.',
        car: { Marca:'Cuarzo', Modelo:'D2', 'Pais de origen':'Indonesia', Garantia:12, 'Duracion de la bateria':36 },
        variantes: [
          { nombre:'32 GB', factor:1.00, car:{ Almacenamiento:32, 'Memoria RAM':3, Color:'Negro' } },
          { nombre:'64 GB', factor:1.24, car:{ Almacenamiento:64, 'Memoria RAM':4, Color:'Azul cielo' } },
        ] },
    ] },

  { nombre: 'Audifonos',
    paleta: ['Marca','Modelo','Garantia','Inalambrico','Impermeable','Duracion de la bateria','Peso','Contenido del paquete'],
    paletaVariante: ['Color','Acabado','Longitud del cable'],
    productos: [
      { nombre: 'Audifonos Sereno ANC', precio: 1450,
        descripcion: 'Diadema cerrada con cancelacion activa y estuche rigido.',
        car: { Marca:'Sereno', Modelo:'ANC-2', Garantia:24, Inalambrico:true, 'Duracion de la bateria':38, Peso:0.26, 'Contenido del paquete':['Audifonos','Estuche rigido','Cable de 3.5 mm','Cable USB-C'] },
        variantes: [
          { nombre:'Negro', factor:1.00, car:{ Color:'Negro', Acabado:'Mate' } },
          { nombre:'Arena', factor:1.00, car:{ Color:'Arena', Acabado:'Mate' } },
        ] },
      { nombre: 'Audifonos Brisa Sport', precio: 620,
        descripcion: 'Intraurales con gancho de silicona, pensados para correr.',
        car: { Marca:'Brisa', Garantia:12, Inalambrico:true, Impermeable:true, 'Duracion de la bateria':9 },
        variantes: [
          { nombre:'Verde lima', factor:1.00, car:{ Color:'Verde lima' } },
          { nombre:'Gris', factor:1.00, car:{ Color:'Gris' } },
        ] },
      { nombre: 'Audifonos Estudio 900', precio: 2100,
        descripcion: 'Monitoreo de referencia con cable desmontable de 3 metros.',
        car: { Marca:'Estudio', Modelo:'900', Garantia:24, Inalambrico:false, Peso:0.31 },
        variantes: [
          { nombre:'Cable 3 m', factor:1.00, car:{ Color:'Negro', 'Longitud del cable':3 } },
        ] },
      { nombre: 'Audifonos Colibri Micro TWS', precio: 980,
        descripcion: 'Intraurales sin cable con estuche de carga del tamano de una caja de fosforos.',
        car: { Marca:'Colibri', Modelo:'TWS-1', Garantia:12, Inalambrico:true, 'Duracion de la bateria':28, Peso:0.045 },
        variantes: [
          { nombre:'Blanco perla', factor:1.00, car:{ Color:'Blanco perla', Acabado:'Brillante' } },
          { nombre:'Negro mate', factor:1.06, car:{ Color:'Negro', Acabado:'Mate' } },
          { nombre:'Verde menta', factor:1.09, car:{ Color:'Verde menta', Acabado:'Mate' } },
        ] },
      { nombre: 'Audifonos Marea Diadema Abierta', precio: 3400,
        descripcion: 'Diadema de rejilla abierta con almohadillas de terciopelo reemplazables.',
        car: { Marca:'Marea', Modelo:'OA-70', Garantia:24, Inalambrico:false, Peso:0.34 },
        variantes: [
          { nombre:'Cable 2 m', factor:1.00, car:{ Color:'Nogal', 'Longitud del cable':2 } },
          { nombre:'Cable 4 m', factor:1.12, car:{ Color:'Nogal', 'Longitud del cable':4, Acabado:'Madera pulida' } },
        ] },
      { nombre: 'Audifonos Duna Trabajo', precio: 1750,
        descripcion: 'Microfono de brazo abatible y base de carga de escritorio para llamadas largas.',
        car: { Marca:'Duna', Garantia:24, Inalambrico:true, 'Duracion de la bateria':45, 'Contenido del paquete':['Audifonos','Base de carga','Cable USB-C','Adaptador de avion'] },
        variantes: [
          { nombre:'Grafito', factor:1.00, car:{ Color:'Grafito', Acabado:'Mate' } },
          { nombre:'Blanco hueso', factor:1.07, car:{ Color:'Blanco hueso', Acabado:'Mate' } },
        ] },
      { nombre: 'Audifonos Zumbo Cable', precio: 210,
        descripcion: 'Intraurales con cable plano antienredos y control de una tecla.',
        car: { Marca:'Zumbo', Modelo:'C1', Inalambrico:false, Peso:0.018 },
        variantes: [
          { nombre:'Cable 1.2 m', factor:1.00, car:{ Color:'Negro', 'Longitud del cable':1.2 } },
        ] },
    ] },

  { nombre: 'Monitores',
    paleta: ['Marca','Modelo','Garantia','Peso','Certificaciones','Contenido del paquete','Material principal'],
    paletaVariante: ['Tamano de pantalla','Tasa de refresco','Color','Acabado'],
    productos: [
      { nombre: 'Monitor Horizonte 27', precio: 2750,
        descripcion: 'Panel IPS de 27 pulgadas con base ajustable en altura.',
        car: { Marca:'Horizonte', Modelo:'H27', Garantia:36, Peso:5.4, Certificaciones:['TUV Eye Comfort','Energy Star'] },
        variantes: [
          { nombre:'75 Hz', factor:1.00, car:{ 'Tamano de pantalla':27, 'Tasa de refresco':75, Color:'Negro' } },
          { nombre:'165 Hz', factor:1.33, car:{ 'Tamano de pantalla':27, 'Tasa de refresco':165, Color:'Negro', Acabado:'Antirreflejo' } },
        ] },
      { nombre: 'Monitor Panorama 34', precio: 5900,
        descripcion: 'Ultrapanoramico curvo de 34 pulgadas, ideal para dos ventanas lado a lado.',
        car: { Marca:'Panorama', Modelo:'UW34', Garantia:24, Peso:7.9, 'Material principal':'Plastico ABS' },
        variantes: [
          { nombre:'100 Hz', factor:1.00, car:{ 'Tamano de pantalla':34, 'Tasa de refresco':100, Color:'Grafito' } },
        ] },
      { nombre: 'Monitor Vitral 24', precio: 1650,
        descripcion: 'Panel IPS de 23.8 pulgadas con entrada HDMI y DisplayPort, base fija.',
        car: { Marca:'Vitral', Modelo:'V24-IPS', Garantia:24, 'Contenido del paquete':['Monitor','Base','Cable HDMI','Cable de poder'] },
        variantes: [
          { nombre:'75 Hz', factor:1.00, car:{ 'Tamano de pantalla':23.8, 'Tasa de refresco':75, Color:'Negro' } },
          { nombre:'100 Hz', factor:1.18, car:{ 'Tamano de pantalla':23.8, 'Tasa de refresco':100, Color:'Negro', Acabado:'Antirreflejo' } },
        ] },
      { nombre: 'Monitor Cenit 32 4K', precio: 4300,
        descripcion: 'Resolucion 4K en 31.5 pulgadas, con calibracion de fabrica y puerto USB-C de 65 W.',
        car: { Marca:'Cenit', Peso:6.8, Certificaciones:['VESA DisplayHDR 400','Energy Star'], 'Material principal':'Aluminio' },
        variantes: [
          { nombre:'60 Hz', factor:1.00, car:{ 'Tamano de pantalla':31.5, 'Tasa de refresco':60, Color:'Plata', Acabado:'Mate' } },
        ] },
      { nombre: 'Monitor Vertice 27 Gamer', precio: 3450,
        descripcion: 'Panel de 27 pulgadas con sincronizacion adaptativa y tiempo de respuesta de 1 ms.',
        car: { Marca:'Vertice', Modelo:'VG27', Garantia:36, Peso:6.1, Certificaciones:['VESA AdaptiveSync Display'] },
        variantes: [
          { nombre:'144 Hz', factor:1.00, car:{ 'Tamano de pantalla':27, 'Tasa de refresco':144, Color:'Negro' } },
          { nombre:'180 Hz', factor:1.16, car:{ 'Tamano de pantalla':27, 'Tasa de refresco':180, Color:'Negro' } },
          { nombre:'240 Hz', factor:1.48, car:{ 'Tamano de pantalla':27, 'Tasa de refresco':240, Color:'Blanco', Acabado:'Mate' } },
        ] },
      { nombre: 'Monitor Nube 22', precio: 1180,
        descripcion: 'Monitor de 21.5 pulgadas para oficina, con altavoces integrados.',
        car: { Marca:'Nube', Modelo:'N22', Garantia:12 },
        variantes: [
          { nombre:'Negro', factor:1.00, car:{ 'Tamano de pantalla':21.5, 'Tasa de refresco':75, Color:'Negro' } },
          { nombre:'Blanco', factor:1.06, car:{ 'Tamano de pantalla':21.5, 'Tasa de refresco':75, Color:'Blanco', Acabado:'Brillante' } },
        ] },
    ] },
] },
{ raiz: 'Hogar', hojas: [

  { nombre: 'Cocina',
    paleta: ['Marca','Material principal','Pais de origen','Garantia','Potencia','Apto para lavavajillas','Contenido del paquete','Peso'],
    paletaVariante: ['Capacidad','Color','Acabado'],
    productos: [
      { nombre: 'Cafetera Alba Espresso', precio: 1980,
        descripcion: 'Cafetera de brazo con vaporizador y bandeja recogegotas extraible.',
        car: { Marca:'Alba', 'Material principal':'Acero inoxidable', Potencia:1350, Garantia:24, 'Contenido del paquete':['Cafetera','Portafiltro doble','Cuchara medidora'] },
        variantes: [
          { nombre:'1.5 L', factor:1.00, car:{ Capacidad:1.5, Color:'Acero', Acabado:'Cepillado' } },
          { nombre:'2.5 L', factor:1.24, car:{ Capacidad:2.5, Color:'Negro' } },
        ] },
      { nombre: 'Juego de ollas Fuego 5 piezas', precio: 1240,
        descripcion: 'Cinco piezas de acero tricapa con tapas de vidrio templado.',
        car: { Marca:'Fuego', 'Material principal':'Acero tricapa', 'Apto para lavavajillas':true, Garantia:120, Peso:6.2 },
        variantes: [
          { nombre:'Estandar', factor:1.00, car:{ Color:'Acero', Acabado:'Pulido' } },
        ] },
      { nombre: 'Licuadora Torbellino 1200', precio: 890,
        descripcion: 'Vaso de vidrio y cuchillas de seis puntas para hielo.',
        car: { Marca:'Torbellino', Potencia:1200, Garantia:12, 'Apto para lavavajillas':true, 'Material principal':'Vidrio' },
        variantes: [
          { nombre:'1.5 L', factor:1.00, car:{ Capacidad:1.5, Color:'Rojo' } },
          { nombre:'2 L', factor:1.15, car:{ Capacidad:2, Color:'Negro' } },
        ] },
      { nombre: 'Hervidor electrico Vapor 1.7', precio: 385,
        descripcion: 'Hervidor de 1.7 litros con apagado automatico y filtro antisarro extraible.',
        car: { Marca:'Vapor', 'Material principal':'Acero inoxidable', Potencia:2000, Garantia:12, 'Apto para lavavajillas':false },
        variantes: [
          { nombre:'Acero', factor:1.00, car:{ Capacidad:1.7, Color:'Acero', Acabado:'Cepillado' } },
          { nombre:'Negro mate', factor:1.08, car:{ Capacidad:1.7, Color:'Negro', Acabado:'Mate' } },
        ] },
      { nombre: 'Cacerola honda Comal 18', precio: 420,
        descripcion: 'Cacerola de acero tricapa con tapa de vidrio templado y mango remachado.',
        car: { Marca:'Comal', 'Material principal':'Acero tricapa', 'Pais de origen':'Italia', Garantia:60, Peso:1.35, 'Contenido del paquete':['Cacerola','Tapa de vidrio'] },
        variantes: [
          { nombre:'16 cm', factor:1.00, car:{ Capacidad:1.6, Color:'Acero', Acabado:'Pulido' } },
          { nombre:'18 cm', factor:1.22, car:{ Capacidad:2.3, Color:'Acero', Acabado:'Pulido' } },
          { nombre:'20 cm', factor:1.45, car:{ Capacidad:3.1, Color:'Acero' } },
        ] },
      { nombre: 'Olla arrocera Grano 8 tazas', precio: 540,
        descripcion: 'Cocina hasta ocho tazas de arroz y pasa sola a mantener el calor.',
        car: { Marca:'Grano', Potencia:700, 'Contenido del paquete':['Olla arrocera','Vaso medidor','Paleta de servir','Canasta vaporera'], 'Apto para lavavajillas':true },
        variantes: [
          { nombre:'1.5 L', factor:1.00, car:{ Capacidad:1.5, Color:'Blanco' } },
          { nombre:'2.8 L', factor:1.30, car:{ Capacidad:2.8, Color:'Blanco', Acabado:'Mate' } },
        ] },
      { nombre: 'Tabla de picar Cedro grande', precio: 195,
        descripcion: 'Tabla de bambu de 40 por 28 cm con canal para jugos en las dos caras.',
        car: { Marca:'Cedro', 'Material principal':'Madera de bambu', 'Apto para lavavajillas':false, Peso:1.4 },
        variantes: [
          { nombre:'Grande', factor:1.00, car:{ Color:'Miel', Acabado:'Aceitado' } },
        ] },
    ] },

  { nombre: 'Muebles',
    paleta: ['Marca','Modelo','Material principal','Peso','Requiere ensamblaje','Garantia','Contenido del paquete','Pais de origen','Certificaciones'],
    paletaVariante: ['Color','Acabado','Talla'],
    productos: [
      { nombre: 'Escritorio Roble 120', precio: 2350,
        descripcion: 'Tablero de 120 por 60 cm con pasacables y estructura de acero.',
        car: { Marca:'Roble', 'Material principal':'Madera de pino', 'Requiere ensamblaje':true, Peso:18.5, Garantia:24, 'Contenido del paquete':['Tablero','Patas','Tornilleria','Llave allen'] },
        variantes: [
          { nombre:'Natural', factor:1.00, car:{ Color:'Natural', Acabado:'Barnizado' } },
          { nombre:'Nogal', factor:1.00, car:{ Color:'Nogal', Acabado:'Barnizado' } },
        ] },
      { nombre: 'Silla ergonomica Vertebra', precio: 3100,
        descripcion: 'Respaldo de malla, soporte lumbar regulable y apoyabrazos 3D.',
        car: { Marca:'Vertebra', 'Material principal':'Malla y nylon', 'Requiere ensamblaje':true, Garantia:60, Peso:14 },
        variantes: [
          { nombre:'Negra', factor:1.00, car:{ Color:'Negro' } },
          { nombre:'Gris', factor:1.00, car:{ Color:'Gris' } },
        ] },
      { nombre: 'Librero Hoja 5 niveles', precio: 1450,
        descripcion: 'Cinco entrepanos de 80 cm de ancho, con anclaje de pared incluido.',
        car: { Marca:'Hoja', Modelo:'L5', 'Material principal':'Aglomerado con chapa de roble', 'Requiere ensamblaje':true, Peso:24, 'Contenido del paquete':['Paneles laterales','Entrepanos','Tornilleria','Llave allen','Anclaje de pared'] },
        variantes: [
          { nombre:'5 niveles roble', factor:1.00, car:{ Color:'Roble claro', Acabado:'Melamina mate' } },
          { nombre:'6 niveles nogal', factor:1.24, car:{ Color:'Nogal', Acabado:'Melamina mate', Talla:'Alto' } },
        ] },
      { nombre: 'Mesa de centro Guijarro', precio: 980,
        descripcion: 'Mesa baja de madera maciza de 100 por 55 cm, llega armada de fabrica.',
        car: { Marca:'Guijarro', 'Material principal':'Madera de encino', Peso:12.6, 'Pais de origen':'Guatemala', 'Requiere ensamblaje':false },
        variantes: [
          { nombre:'Natural', factor:1.00, car:{ Color:'Natural', Acabado:'Aceite mate' } },
        ] },
      { nombre: 'Silla de comedor Vara', precio: 420,
        descripcion: 'Silla de madera de haya con respaldo de listones y asiento a 45 cm del piso.',
        car: { Marca:'Vara', Modelo:'C-02', 'Material principal':'Madera de haya', 'Requiere ensamblaje':true, Garantia:12 },
        variantes: [
          { nombre:'Natural', factor:1.00, car:{ Color:'Natural', Acabado:'Barnizado' } },
          { nombre:'Negra', factor:1.10, car:{ Color:'Negro', Acabado:'Laca mate' } },
          { nombre:'Tapizada gris', factor:1.35, car:{ Color:'Gris', Acabado:'Tapizado' } },
        ] },
      { nombre: 'Comoda Sendero 4 gavetas', precio: 1890,
        descripcion: 'Gavetas con correderas metalicas y tope antivuelco para fijar a la pared.',
        car: { Marca:'Sendero', 'Material principal':'MDF laminado', Peso:31.5, 'Requiere ensamblaje':true, Garantia:24, Certificaciones:['FSC Mix'] },
        variantes: [
          { nombre:'4 gavetas', factor:1.00, car:{ Color:'Blanco', Acabado:'Mate' } },
          { nombre:'6 gavetas', factor:1.38, car:{ Color:'Blanco', Acabado:'Mate', Talla:'Ancha' } },
        ] },
    ] },

  { nombre: 'Iluminacion',
    paleta: ['Marca','Modelo','Potencia','Garantia','Inalambrico','Material principal','Certificaciones','Pais de origen','Peso'],
    paletaVariante: ['Color','Acabado','Longitud del cable'],
    productos: [
      { nombre: 'Lampara de escritorio Faro', precio: 480,
        descripcion: 'Brazo articulado con tres temperaturas de color y puerto USB.',
        car: { Marca:'Faro', Potencia:9, Garantia:24, 'Material principal':'Aluminio' },
        variantes: [
          { nombre:'Blanca', factor:1.00, car:{ Color:'Blanco', 'Longitud del cable':1.8 } },
          { nombre:'Negra', factor:1.00, car:{ Color:'Negro', 'Longitud del cable':1.8 } },
        ] },
      { nombre: 'Tira LED Aurora 5 m', precio: 320,
        descripcion: 'Cinco metros regulables con control remoto y adhesivo 3M.',
        car: { Marca:'Aurora', Potencia:24, Inalambrico:true, Garantia:12, Certificaciones:['CE','RoHS'] },
        variantes: [
          { nombre:'Multicolor', factor:1.00, car:{ Color:'Multicolor', 'Longitud del cable':5 } },
        ] },
      { nombre: 'Lampara colgante Candela 40', precio: 760,
        descripcion: 'Pantalla tejida de mimbre de 40 cm de diametro con cable textil regulable.',
        car: { Marca:'Candela', Modelo:'C40', 'Material principal':'Mimbre natural', Potencia:12, Peso:1.35 },
        variantes: [
          { nombre:'Mimbre natural', factor:1.00, car:{ Color:'Beige', 'Longitud del cable':1.2 } },
          { nombre:'Negro mate', factor:1.15, car:{ Color:'Negro', Acabado:'Mate', 'Longitud del cable':1.2 } },
        ] },
      { nombre: 'Lampara de pie Vigia 165', precio: 1150,
        descripcion: 'Poste de 165 cm con pedal de encendido y difusor de tela orientable.',
        car: { Marca:'Vigia', Modelo:'P165', Potencia:18, Garantia:24, 'Pais de origen':'Polonia', Peso:4.6 },
        variantes: [
          { nombre:'Negro', factor:1.00, car:{ Color:'Negro', 'Longitud del cable':2 } },
          { nombre:'Laton cepillado', factor:1.18, car:{ Color:'Laton', Acabado:'Cepillado', 'Longitud del cable':2 } },
          { nombre:'Nogal y laton', factor:1.35, car:{ Color:'Nogal', Acabado:'Barnizado', 'Longitud del cable':2.5 } },
        ] },
      { nombre: 'Plafon LED Solaz 24', precio: 540,
        descripcion: 'Plafon de superficie de 40 cm que se atornilla directo al techo, sin balastro.',
        car: { Marca:'Solaz', Potencia:24, Garantia:36, Certificaciones:['CE','RoHS','Energy Star'], 'Material principal':'Acrilico opalino' },
        variantes: [
          { nombre:'Blanco 24 W', factor:1.00, car:{ Color:'Blanco', Acabado:'Satinado' } },
        ] },
      { nombre: 'Farol solar de jardin Luciernaga', precio: 215,
        descripcion: 'Estaca para cesped con panel solar y sensor de anochecer, se clava sin cablear.',
        car: { Marca:'Luciernaga', Modelo:'Jardin 4', Inalambrico:true, Peso:0.34 },
        variantes: [
          { nombre:'Negro mate', factor:1.00, car:{ Color:'Negro', Acabado:'Mate' } },
          { nombre:'Cobre envejecido', factor:1.22, car:{ Color:'Cobre', Acabado:'Envejecido' } },
        ] },
    ] },
] },
{ raiz: 'Ropa de hombre', hojas: [

  { nombre: 'Camisas',
    paleta: ['Marca','Modelo','Material principal','Origen del algodon','Pais de origen','Certificaciones','Peso','Contenido del paquete'],
    paletaVariante: ['Talla','Color','Acabado'],
    productos: [
      { nombre: 'Camisa de lino manga larga', precio: 340,
        descripcion: 'Lino lavado de corte regular con cuello italiano.',
        car: { Marca:'Telar', 'Material principal':'Lino', 'Pais de origen':'Portugal' },
        variantes: [
          { nombre:'S azul', factor:1.00, car:{ Talla:'S', Color:'Azul' } },
          { nombre:'M azul', factor:1.00, car:{ Talla:'M', Color:'Azul' } },
          { nombre:'L blanca', factor:1.00, car:{ Talla:'L', Color:'Blanco' } },
        ] },
      { nombre: 'Camisa oxford clasica', precio: 290,
        descripcion: 'Oxford de algodon peinado, cuello con botones.',
        car: { Marca:'Telar', 'Material principal':'Algodon', 'Origen del algodon':'Peru', Certificaciones:['OEKO-TEX Standard 100'] },
        variantes: [
          { nombre:'M celeste', factor:1.00, car:{ Talla:'M', Color:'Celeste', Acabado:'Lavado suave' } },
          { nombre:'L celeste', factor:1.00, car:{ Talla:'L', Color:'Celeste' } },
        ] },
      { nombre: 'Camisa guayabera Xelaju', precio: 395,
        descripcion: 'Guayabera de lino con cuatro bolsas y alforzas verticales al frente y a la espalda.',
        car: { Marca:'Xelaju', 'Material principal':'Lino', 'Pais de origen':'Guatemala', Peso:0.24 },
        variantes: [
          { nombre:'M blanca', factor:1.00, car:{ Talla:'M', Color:'Blanco' } },
          { nombre:'L hueso', factor:1.06, car:{ Talla:'L', Color:'Hueso' } },
          { nombre:'XL hueso', factor:1.12, car:{ Talla:'XL', Color:'Hueso', Acabado:'Prelavado' } },
        ] },
      { nombre: 'Camisa de vestir Meridiano', precio: 315,
        descripcion: 'Popelina de algodon peinado con cuello semiingles y punos de gemelo opcional.',
        car: { Marca:'Meridiano', Modelo:'MD-2', 'Material principal':'Algodon popelina', 'Origen del algodon':'Egipto', Certificaciones:['OEKO-TEX Standard 100'] },
        variantes: [
          { nombre:'M blanca', factor:1.00, car:{ Talla:'M', Color:'Blanco', Acabado:'Antiarrugas' } },
          { nombre:'L gris perla', factor:1.08, car:{ Talla:'L', Color:'Gris perla', Acabado:'Antiarrugas' } },
        ] },
      { nombre: 'Camisa de mezclilla Remache', precio: 430,
        descripcion: 'Mezclilla de 6 onzas con botones a presion y canesu doble en la espalda.',
        car: { Marca:'Remache', Modelo:'R-14', 'Material principal':'Mezclilla de algodon', 'Origen del algodon':'Estados Unidos', 'Pais de origen':'Mexico', Peso:0.48 },
        variantes: [
          { nombre:'M azul indigo', factor:1.00, car:{ Talla:'M', Color:'Azul indigo' } },
          { nombre:'L azul claro', factor:1.09, car:{ Talla:'L', Color:'Azul claro', Acabado:'Lavado a la piedra' } },
        ] },
      { nombre: 'Camisa polo pique Cardumen', precio: 245,
        descripcion: 'Pique de algodon con cuello acanalado y abertura de tres botones.',
        car: { Marca:'Cardumen', 'Material principal':'Pique de algodon', 'Origen del algodon':'Peru', 'Contenido del paquete':['Camisa','Botones de repuesto'] },
        variantes: [
          { nombre:'M azul marino', factor:1.00, car:{ Talla:'M', Color:'Azul marino', Acabado:'Prelavado' } },
        ] },
    ] },

  { nombre: 'Pantalones',
    paleta: ['Marca','Modelo','Material principal','Pais de origen','Origen del algodon','Certificaciones','Peso'],
    paletaVariante: ['Talla','Color','Acabado'],
    productos: [
      { nombre: 'Pantalon chino resistente', precio: 420,
        descripcion: 'Sarga de algodon con elastano, corte recto.',
        car: { Marca:'Rumbo', 'Material principal':'Algodon y elastano', 'Pais de origen':'Guatemala' },
        variantes: [
          { nombre:'32 beige', factor:1.00, car:{ Talla:'32', Color:'Beige' } },
          { nombre:'34 beige', factor:1.00, car:{ Talla:'34', Color:'Beige' } },
          { nombre:'34 azul', factor:1.00, car:{ Talla:'34', Color:'Azul marino' } },
        ] },
      { nombre: 'Pantalon de mezclilla Yunque', precio: 520,
        descripcion: 'Mezclilla rigida de 13 onzas, cinco bolsas y remaches de cobre en los esfuerzos.',
        car: { Marca:'Yunque', Modelo:'Y-501', 'Material principal':'Mezclilla 13 oz', 'Origen del algodon':'Estados Unidos', Peso:0.72 },
        variantes: [
          { nombre:'32 indigo crudo', factor:1.00, car:{ Talla:'32', Color:'Indigo crudo' } },
          { nombre:'34 negro', factor:1.07, car:{ Talla:'34', Color:'Negro', Acabado:'Lavado a la piedra' } },
        ] },
      { nombre: 'Pantalon cargo Vereda', precio: 480,
        descripcion: 'Ripstop con seis bolsas, rodilla articulada y jareta en el tobillo.',
        car: { Marca:'Vereda', 'Material principal':'Ripstop de algodon', 'Pais de origen':'Vietnam', Peso:0.58 },
        variantes: [
          { nombre:'32 verde oliva', factor:1.00, car:{ Talla:'32', Color:'Verde oliva' } },
          { nombre:'34 arena', factor:1.06, car:{ Talla:'34', Color:'Arena' } },
          { nombre:'36 negro', factor:1.12, car:{ Talla:'36', Color:'Negro', Acabado:'Repelente al agua' } },
        ] },
      { nombre: 'Pantalon de vestir Consulado', precio: 610,
        descripcion: 'Lana fria de corte ajustado, con pretina interior antideslizante y bajo sin dobladillo.',
        car: { Marca:'Consulado', Modelo:'CS-Slim', 'Material principal':'Lana fria', Certificaciones:['Woolmark'] },
        variantes: [
          { nombre:'32 gris oxford', factor:1.00, car:{ Talla:'32', Color:'Gris oxford', Acabado:'Planchado permanente' } },
        ] },
      { nombre: 'Pantalon jogger Ocaso', precio: 285,
        descripcion: 'Felpa de algodon con cintura elastica, cordon plano y punos acanalados.',
        car: { Marca:'Ocaso', 'Material principal':'Felpa de algodon', 'Origen del algodon':'India' },
        variantes: [
          { nombre:'M gris jaspe', factor:1.00, car:{ Talla:'M', Color:'Gris jaspe' } },
          { nombre:'L negro', factor:1.08, car:{ Talla:'L', Color:'Negro', Acabado:'Perchado interior' } },
        ] },
    ] },

  { nombre: 'Zapatos',
    paleta: ['Marca','Modelo','Material principal','Impermeable','Garantia','Pais de origen','Peso','Certificaciones'],
    paletaVariante: ['Numero de calzado','Color','Acabado'],
    productos: [
      { nombre: 'Zapato de cuero Senda', precio: 780,
        descripcion: 'Cuero vacuno con suela de goma cosida.',
        car: { Marca:'Senda', 'Material principal':'Cuero vacuno', 'Pais de origen':'Leon', Peso:0.82 },
        variantes: [
          { nombre:'40 cafe', factor:1.00, car:{ 'Numero de calzado':40, Color:'Cafe' } },
          { nombre:'42 cafe', factor:1.00, car:{ 'Numero de calzado':42, Color:'Cafe' } },
          { nombre:'42 negro', factor:1.00, car:{ 'Numero de calzado':42, Color:'Negro', Acabado:'Pulido' } },
        ] },
      { nombre: 'Bota impermeable Cumbre', precio: 1150,
        descripcion: 'Membrana impermeable y suela con agarre para roca mojada.',
        car: { Marca:'Cumbre', 'Material principal':'Nobuck', Impermeable:true, Garantia:12, Peso:1.15 },
        variantes: [
          { nombre:'41', factor:1.00, car:{ 'Numero de calzado':41, Color:'Marron' } },
          { nombre:'43', factor:1.00, car:{ 'Numero de calzado':43, Color:'Marron' } },
        ] },
      { nombre: 'Tenis urbano Vereda 90', precio: 650,
        descripcion: 'Malla transpirable sobre suela de EVA inyectada, para caminar todo el dia.',
        car: { Marca:'Vereda', Modelo:'V-90', 'Material principal':'Piel sintetica y malla', Peso:0.68 },
        variantes: [
          { nombre:'39 blanco', factor:1.00, car:{ 'Numero de calzado':39, Color:'Blanco' } },
          { nombre:'41 blanco', factor:1.05, car:{ 'Numero de calzado':41, Color:'Blanco' } },
          { nombre:'43 gris', factor:1.08, car:{ 'Numero de calzado':43, Color:'Gris', Acabado:'Mate' } },
        ] },
      { nombre: 'Mocasin de gamuza Roble', precio: 890,
        descripcion: 'Gamuza sin forro con suela flexible de goma, se usa sin calcetin.',
        car: { Marca:'Roble', 'Material principal':'Gamuza', 'Pais de origen':'Espana', Garantia:6, Peso:0.74 },
        variantes: [
          { nombre:'40 azul', factor:1.00, car:{ 'Numero de calzado':40, Color:'Azul marino' } },
          { nombre:'42 arena', factor:1.08, car:{ 'Numero de calzado':42, Color:'Arena', Acabado:'Cepillado' } },
        ] },
      { nombre: 'Bota de trabajo Yunque S3', precio: 1320,
        descripcion: 'Puntera de acero y plantilla antiperforacion, suela resistente a hidrocarburos.',
        car: { Marca:'Yunque', Modelo:'S3-Punta', 'Material principal':'Cuero graso', Impermeable:true, Certificaciones:['EN ISO 20345 S3','ASTM F2413'], Peso:1.42 },
        variantes: [
          { nombre:'40 negro', factor:1.00, car:{ 'Numero de calzado':40, Color:'Negro' } },
          { nombre:'42 negro', factor:1.06, car:{ 'Numero de calzado':42, Color:'Negro' } },
          { nombre:'44 miel', factor:1.11, car:{ 'Numero de calzado':44, Color:'Miel', Acabado:'Engrasado' } },
        ] },
      { nombre: 'Sandalia de cuero Litoral', precio: 410,
        descripcion: 'Tres tiras de cuero curtido con vegetales y hebilla de laton macizo.',
        car: { Marca:'Litoral', 'Material principal':'Cuero curtido vegetal', 'Pais de origen':'Guatemala', Impermeable:false },
        variantes: [
          { nombre:'41 cafe', factor:1.00, car:{ 'Numero de calzado':41, Color:'Cafe' } },
        ] },
    ] },
] },
{ raiz: 'Deportes', hojas: [

  { nombre: 'Futbol',
    paleta: ['Marca','Modelo','Material principal','Certificaciones','Pais de origen','Peso','Garantia','Contenido del paquete'],
    paletaVariante: ['Talla','Color'],
    productos: [
      { nombre: 'Balon de futbol numero 5', precio: 260,
        descripcion: 'Costura termosellada, apto para cancha de grama sintetica.',
        car: { Marca:'Portero', 'Material principal':'Poliuretano', Certificaciones:['FIFA Basic'], Peso:0.43 },
        variantes: [
          { nombre:'Blanco', factor:1.00, car:{ Talla:'5', Color:'Blanco' } },
          { nombre:'Naranja', factor:1.00, car:{ Talla:'5', Color:'Naranja' } },
        ] },
      { nombre: 'Espinilleras Muralla', precio: 145,
        descripcion: 'Placa rigida con espuma de alta densidad y mallas sujetadoras.',
        car: { Marca:'Muralla', 'Material principal':'Polipropileno', Peso:0.16 },
        variantes: [
          { nombre:'M', factor:1.00, car:{ Talla:'M', Color:'Negro' } },
          { nombre:'L', factor:1.00, car:{ Talla:'L', Color:'Negro' } },
        ] },
      { nombre: 'Guantes de portero Zarpa 300', precio: 385,
        descripcion: 'Latex de cuatro milimetros con corte negativo y correa elastica ancha.',
        car: { Marca:'Zarpa', Modelo:'G300', 'Material principal':'Latex y neopreno', Peso:0.22, 'Contenido del paquete':['Par de guantes','Bolsa de malla'] },
        variantes: [
          { nombre:'Talla 8', factor:1.00, car:{ Talla:'8', Color:'Negro' } },
          { nombre:'Talla 10', factor:1.07, car:{ Talla:'10', Color:'Amarillo' } },
        ] },
      { nombre: 'Zapato de tacos Relampago FG', precio: 690,
        descripcion: 'Doce tacos conicos para grama natural firme y empeine de microfibra sin costuras.',
        car: { Marca:'Relampago', 'Material principal':'Microfibra', Peso:0.24, 'Pais de origen':'Vietnam' },
        variantes: [
          { nombre:'40 negro', factor:1.00, car:{ Talla:'40', Color:'Negro' } },
          { nombre:'42 negro', factor:1.05, car:{ Talla:'42', Color:'Negro' } },
          { nombre:'42 rojo', factor:1.09, car:{ Talla:'42', Color:'Rojo' } },
        ] },
      { nombre: 'Red de porteria Trama 7 x 2', precio: 940,
        descripcion: 'Par de redes de malla trenzada para porteria reglamentaria, con ganchos incluidos.',
        car: { Marca:'Trama', Modelo:'R72', 'Material principal':'Polipropileno trenzado', Peso:4.6, Garantia:12, 'Contenido del paquete':['Dos redes','Cincuenta ganchos plasticos','Bolsa de transporte'] },
        variantes: [
          { nombre:'Par 7 x 2 m', factor:1.00, car:{ Color:'Blanco' } },
        ] },
      { nombre: 'Uniforme de entrenamiento Cantera', precio: 275,
        descripcion: 'Camiseta, pantaloneta y medias en tejido que seca rapido, sin numeracion.',
        car: { Marca:'Cantera', 'Material principal':'Poliester reciclado', Certificaciones:['OEKO-TEX Standard 100'], 'Contenido del paquete':['Camiseta','Pantaloneta','Par de medias'] },
        variantes: [
          { nombre:'M azul', factor:1.00, car:{ Talla:'M', Color:'Azul' } },
          { nombre:'L azul', factor:1.06, car:{ Talla:'L', Color:'Azul' } },
          { nombre:'L verde', factor:1.06, car:{ Talla:'L', Color:'Verde' } },
        ] },
    ] },

  { nombre: 'Ciclismo',
    paleta: ['Marca','Modelo','Material principal','Garantia','Peso','Certificaciones','Contenido del paquete','Pais de origen'],
    paletaVariante: ['Talla','Color','Acabado'],
    productos: [
      { nombre: 'Casco de ruta Aerodino', precio: 690,
        descripcion: 'Veintidos ventilaciones y ajuste micrometrico en la nuca.',
        car: { Marca:'Aerodino', 'Material principal':'Policarbonato y EPS', Certificaciones:['CPSC','EN 1078'], Peso:0.27, Garantia:24 },
        variantes: [
          { nombre:'M blanco', factor:1.00, car:{ Talla:'M', Color:'Blanco' } },
          { nombre:'L negro', factor:1.00, car:{ Talla:'L', Color:'Negro', Acabado:'Mate' } },
        ] },
      { nombre: 'Bomba de piso Piston', precio: 310,
        descripcion: 'Manometro analogico hasta 160 psi y cabezal para las dos valvulas.',
        car: { Marca:'Piston', 'Material principal':'Acero', Garantia:24, 'Contenido del paquete':['Bomba','Adaptador de balon','Aguja'] },
        variantes: [
          { nombre:'Estandar', factor:1.00, car:{ Color:'Negro' } },
        ] },
      { nombre: 'Guantes de ciclismo Palma Corta', precio: 210,
        descripcion: 'Medio dedo con gel en la eminencia tenar y lengueta para quitarlos de un tiron.',
        car: { Marca:'Palma', 'Material principal':'Gamuza sintetica y lycra', Peso:0.09, 'Pais de origen':'Taiwan' },
        variantes: [
          { nombre:'S negro', factor:1.00, car:{ Talla:'S', Color:'Negro' } },
          { nombre:'M negro', factor:1.05, car:{ Talla:'M', Color:'Negro' } },
          { nombre:'L gris', factor:1.05, car:{ Talla:'L', Color:'Gris' } },
        ] },
      { nombre: 'Sillin de ruta Vertebra SR-2', precio: 540,
        descripcion: 'Canal central aliviado y rieles de acero cromado compatibles con cualquier tija.',
        car: { Marca:'Vertebra', Modelo:'SR-2', 'Material principal':'Base de nailon y rieles de acero', Garantia:24, Peso:0.29 },
        variantes: [
          { nombre:'143 mm', factor:1.00, car:{ Talla:'143 mm', Color:'Negro' } },
          { nombre:'155 mm', factor:1.08, car:{ Talla:'155 mm', Color:'Negro', Acabado:'Mate' } },
        ] },
      { nombre: 'Maillot de ruta Peloton', precio: 460,
        descripcion: 'Cierre completo, tres bolsillos traseros y paneles de malla bajo los brazos.',
        car: { Marca:'Peloton', 'Material principal':'Poliester con paneles de malla', 'Pais de origen':'Colombia', Peso:0.16, Certificaciones:['OEKO-TEX Standard 100'] },
        variantes: [
          { nombre:'M naranja', factor:1.00, car:{ Talla:'M', Color:'Naranja' } },
          { nombre:'L naranja', factor:1.06, car:{ Talla:'L', Color:'Naranja' } },
          { nombre:'L azul', factor:1.06, car:{ Talla:'L', Color:'Azul', Acabado:'Mate' } },
        ] },
      { nombre: 'Candado plegable Cerrojo F8', precio: 630,
        descripcion: 'Ocho barras de acero templado que se pliegan en una funda atornillable al cuadro.',
        car: { Marca:'Cerrojo', Modelo:'F8', 'Material principal':'Acero templado', Garantia:36, Peso:1.05, Certificaciones:['Sold Secure Silver'] },
        variantes: [
          { nombre:'Estandar', factor:1.00, car:{ Color:'Negro', Acabado:'Mate' } },
        ] },
    ] },

  { nombre: 'Fitness',
    paleta: ['Marca','Modelo','Material principal','Nivel de resistencia','Peso','Contenido del paquete','Certificaciones','Pais de origen'],
    paletaVariante: ['Color','Talla'],
    productos: [
      { nombre: 'Set de bandas elasticas', precio: 195,
        descripcion: 'Cinco bandas de latex con distinta resistencia y bolsa de malla.',
        car: { Marca:'Tension', 'Material principal':'Latex natural', 'Nivel de resistencia':'Progresiva 5 a 25 kg', 'Contenido del paquete':['5 bandas','Bolsa de malla','Guia de ejercicios'] },
        variantes: [
          { nombre:'Set completo', factor:1.00, car:{ Color:'Multicolor' } },
        ] },
      { nombre: 'Tapete de yoga Raiz 6 mm', precio: 380,
        descripcion: 'Seis milimetros de TPE con superficie antideslizante en las dos caras.',
        car: { Marca:'Raiz', 'Material principal':'TPE', Peso:1.1 },
        variantes: [
          { nombre:'Verde', factor:1.00, car:{ Color:'Verde' } },
          { nombre:'Morado', factor:1.00, car:{ Color:'Morado' } },
        ] },
      { nombre: 'Mancuernas ajustables Vertice 20 kg', precio: 1180,
        descripcion: 'Par de mancuernas con discos intercambiables de 1.25 a 5 kg y seguro de rosca.',
        car: { Marca:'Vertice', Modelo:'AJ-20', 'Material principal':'Acero con recubrimiento de goma', Peso:20.4, 'Contenido del paquete':['2 barras cortas','Discos de 1.25 a 5 kg','Llave de seguro'] },
        variantes: [
          { nombre:'Par de 20 kg', factor:1.00, car:{ Color:'Negro' } },
          { nombre:'Par de 30 kg', factor:1.38, car:{ Color:'Negro' } },
        ] },
      { nombre: 'Pesa rusa Yunque', precio: 430,
        descripcion: 'Hierro fundido de una sola pieza con asa ancha para agarre a dos manos.',
        car: { Marca:'Yunque', 'Material principal':'Hierro fundido con recubrimiento vinilico', 'Pais de origen':'Mexico', Certificaciones:['ISO 20957'] },
        variantes: [
          { nombre:'12 kg', factor:1.00, car:{ Talla:'12 kg', Color:'Negro mate' } },
          { nombre:'16 kg', factor:1.28, car:{ Talla:'16 kg', Color:'Negro mate' } },
          { nombre:'20 kg', factor:1.55, car:{ Talla:'20 kg', Color:'Azul' } },
        ] },
      { nombre: 'Cuerda de salto Relampago', precio: 125,
        descripcion: 'Cable de acero de tres metros con rodamientos, ajustable a la altura del usuario.',
        car: { Marca:'Relampago', 'Material principal':'Cable de acero forrado en PVC', 'Nivel de resistencia':'Rodamiento rapido para doble salto', Peso:0.24 },
        variantes: [
          { nombre:'Cable de 3 m', factor:1.00, car:{ Color:'Negro y rojo' } },
        ] },
      { nombre: 'Rodillo de liberacion Nudo', precio: 210,
        descripcion: 'Rodillo de espuma con relieve en cuadros para masaje de cuadriceps y espalda alta.',
        car: { Marca:'Nudo', Modelo:'R33', 'Material principal':'EVA de alta densidad', 'Nivel de resistencia':'Firme', Peso:0.62, 'Contenido del paquete':['Rodillo','Poster de rutinas'] },
        variantes: [
          { nombre:'33 cm', factor:1.00, car:{ Talla:'33 cm', Color:'Gris' } },
          { nombre:'45 cm', factor:1.30, car:{ Talla:'45 cm', Color:'Naranja' } },
        ] },
    ] },
] },
{ raiz: 'Libros', hojas: [

  { nombre: 'Literatura',
    paleta: ['Autor','Editorial','Paginas','Idioma','Anio de publicacion','Peso','Pais de origen','Material principal','Certificaciones'],
    paletaVariante: ['Formato','Color'],
    productos: [
      { nombre: 'El camino de las nubes', precio: 180,
        descripcion: 'Novela de viaje por el altiplano, ganadora del premio nacional.',
        car: { Autor:'Renata Solis', Editorial:'Piedra Santa', Paginas:312, Idioma:'Espanol', 'Anio de publicacion':2024 },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
          { nombre:'Pasta dura', factor:1.55, car:{ Formato:'Pasta dura' } },
        ] },
      { nombre: 'Cuentos de la ceiba', precio: 145,
        descripcion: 'Doce relatos breves sobre la memoria y el desarraigo.',
        car: { Autor:'Tomas Arriaga', Editorial:'Cadejo', Paginas:186, Idioma:'Espanol', 'Anio de publicacion':2022 },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
        ] },
      { nombre: 'La casa de los relojes detenidos', precio: 195,
        descripcion: 'Novela sobre tres hermanas que heredan una relojeria y el silencio de su padre.',
        car: { Autor:'Ines Marroquin', Editorial:'Vagalume', Paginas:344, Idioma:'Espanol', 'Anio de publicacion':2023, Peso:0.48 },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
          { nombre:'Pasta dura', factor:1.48, car:{ Formato:'Pasta dura', Color:'Azul indigo' } },
        ] },
      { nombre: 'Cartas al puerto seco', precio: 95,
        descripcion: 'Novela epistolar entre un aduanero y una traductora que nunca llegan a conocerse.',
        car: { Autor:'Baltasar Quinones', Editorial:'Sombrilla Roja', Paginas:228, 'Anio de publicacion':2021 },
        variantes: [
          { nombre:'Digital', factor:1.00, car:{ Formato:'EPUB' } },
          { nombre:'Pasta blanda', factor:1.42, car:{ Formato:'Pasta blanda' } },
          { nombre:'Pasta dura', factor:1.88, car:{ Formato:'Pasta dura', Color:'Verde musgo' } },
        ] },
      { nombre: 'Nadie duerme en Tecpanal', precio: 210,
        descripcion: 'Coral de un pueblo que pasa una noche entera esperando que baje el rio.',
        car: { Autor:'Mariela Sandoval', Editorial:'Tinta Nocturna', Paginas:412, Idioma:'Espanol', 'Pais de origen':'Guatemala', 'Material principal':'Papel bond ahuesado' },
        variantes: [
          { nombre:'Pasta dura', factor:1.00, car:{ Formato:'Pasta dura', Color:'Negro' } },
        ] },
      { nombre: 'Antologia del ruido', precio: 135,
        descripcion: 'Poemario reunido de veinte anios de trabajo, con notas del propio autor.',
        car: { Autor:'Efrain Toledo', Editorial:'Guacamayo', Paginas:148, 'Anio de publicacion':2025, Certificaciones:['FSC Mixto'] },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda', Color:'Crema' } },
          { nombre:'Edicion ilustrada', factor:1.62, car:{ Formato:'Pasta dura', Color:'Rojo' } },
        ] },
    ] },

  { nombre: 'Tecnicos',
    paleta: ['Autor','Editorial','Paginas','Idioma','Anio de publicacion','Certificaciones','Peso','Pais de origen','Material principal'],
    paletaVariante: ['Formato'],
    productos: [
      { nombre: 'Bases de datos distribuidas', precio: 620,
        descripcion: 'Consistencia, particionado y replicacion, con ejercicios resueltos.',
        car: { Autor:'H. Ortega', Editorial:'Tecnos', Paginas:540, Idioma:'Espanol', 'Anio de publicacion':2025 },
        variantes: [
          { nombre:'Pasta dura', factor:1.00, car:{ Formato:'Pasta dura' } },
          { nombre:'Digital', factor:0.55, car:{ Formato:'PDF con DRM' } },
        ] },
      { nombre: 'Redes industriales y buses de campo', precio: 580,
        descripcion: 'Topologias, temporizacion y diagnostico de fallas en Modbus, Profibus y CAN.',
        car: { Autor:'M. Zelaya', Editorial:'Arista Tecnica', Paginas:468, Idioma:'Espanol', 'Anio de publicacion':2024, Peso:1.05 },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
          { nombre:'Pasta dura', factor:1.34, car:{ Formato:'Pasta dura' } },
        ] },
      { nombre: 'Calculo numerico con ejercicios resueltos', precio: 495,
        descripcion: 'Metodos iterativos, interpolacion y error de redondeo, con 320 problemas resueltos.',
        car: { Autor:'L. Barrientos', Editorial:'Nodo Editorial', Paginas:612, 'Anio de publicacion':2023 },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
        ] },
      { nombre: 'Manual de instalaciones electricas residenciales', precio: 340,
        descripcion: 'Calculo de cargas, calibres y protecciones para vivienda, con tablas desplegables.',
        car: { Autor:'C. Pineda', Editorial:'Meridiano', Paginas:288, Idioma:'Espanol', 'Pais de origen':'Colombia', 'Material principal':'Papel offset de 90 g' },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
          { nombre:'Espiral', factor:1.18, car:{ Formato:'Espiral' } },
          { nombre:'Pasta dura', factor:1.55, car:{ Formato:'Pasta dura' } },
        ] },
      { nombre: 'Introduccion al modelado de sistemas embebidos', precio: 650,
        descripcion: 'Maquinas de estado, planificacion en tiempo real y consumo, sobre microcontroladores de 32 bits.',
        car: { Autor:'R. Villagran', Editorial:'Compendio Austral', Paginas:524, Certificaciones:['FSC Mixto'], Peso:1.18 },
        variantes: [
          { nombre:'Pasta dura', factor:1.00, car:{ Formato:'Pasta dura' } },
          { nombre:'Pasta dura con acceso digital', factor:1.22, car:{ Formato:'Pasta dura con codigo de acceso' } },
        ] },
    ] },
] },
{ raiz: 'Belleza', hojas: [

  { nombre: 'Cuidado facial',
    paleta: ['Marca','Modelo','Tipo de piel','Ingredientes destacados','Pais de origen','Certificaciones','Contenido del paquete','Peso'],
    paletaVariante: ['Volumen','Color'],
    productos: [
      { nombre: 'Serum de niacinamida 10%', precio: 210,
        descripcion: 'Serum ligero para textura y marcas, de uso nocturno.',
        car: { Marca:'Clara', 'Tipo de piel':'Mixta a grasa', 'Ingredientes destacados':['Niacinamida','Zinc PCA'], 'Pais de origen':'Corea del Sur' },
        variantes: [
          { nombre:'30 ml', factor:1.00, car:{ Volumen:30 } },
          { nombre:'50 ml', factor:1.48, car:{ Volumen:50 } },
        ] },
      { nombre: 'Protector solar mineral FPS 50', precio: 265,
        descripcion: 'Filtro mineral sin fragancia, apto para piel sensible.',
        car: { Marca:'Clara', 'Tipo de piel':'Sensible', 'Ingredientes destacados':['Oxido de zinc','Vitamina E'], Certificaciones:['Dermatologicamente probado'] },
        variantes: [
          { nombre:'50 ml', factor:1.00, car:{ Volumen:50 } },
        ] },
      { nombre: 'Crema hidratante nocturna Alba', precio: 320,
        descripcion: 'Crema densa de uso nocturno, se absorbe sin dejar la cara brillante.',
        car: { Marca:'Alba', Modelo:'AN-50', 'Tipo de piel':'Seca', 'Ingredientes destacados':['Acido hialuronico','Manteca de karite'], Peso:0.12 },
        variantes: [
          { nombre:'50 ml', factor:1.00, car:{ Volumen:50 } },
          { nombre:'100 ml', factor:1.55, car:{ Volumen:100 } },
        ] },
      { nombre: 'Limpiador en gel Verdo', precio: 145,
        descripcion: 'Gel transparente que quita el exceso de grasa sin resecar la piel.',
        car: { Marca:'Verdo', 'Tipo de piel':'Grasa', 'Pais de origen':'Mexico', 'Contenido del paquete':['Frasco con dosificador','Guia de uso'] },
        variantes: [
          { nombre:'150 ml', factor:1.00, car:{ Volumen:150 } },
          { nombre:'250 ml', factor:1.35, car:{ Volumen:250 } },
          { nombre:'400 ml', factor:1.72, car:{ Volumen:400, Color:'Frasco ambar' } },
        ] },
      { nombre: 'Exfoliante enzimatico Papilo', precio: 235,
        descripcion: 'Exfoliante sin granos: actua por enzimas y se enjuaga con agua tibia.',
        car: { Marca:'Papilo', Modelo:'EZ-2', 'Ingredientes destacados':['Enzima de papaya','Avena coloidal'], Certificaciones:['No testeado en animales','Vegano'], Peso:0.09 },
        variantes: [
          { nombre:'75 ml', factor:1.00, car:{ Volumen:75 } },
        ] },
      { nombre: 'Contorno de ojos Lumine', precio: 280,
        descripcion: 'Contorno ligero para bolsas y lineas finas, con aplicador frio de ceramica.',
        car: { Marca:'Lumine', 'Tipo de piel':'Todo tipo', 'Pais de origen':'Corea del Sur', Certificaciones:['Dermatologicamente probado'], 'Contenido del paquete':['Frasco','Aplicador de ceramica'], Peso:0.05 },
        variantes: [
          { nombre:'15 ml', factor:1.00, car:{ Volumen:15 } },
          { nombre:'30 ml', factor:1.45, car:{ Volumen:30 } },
        ] },
    ] },

  { nombre: 'Fragancias',
    paleta: ['Marca','Tipo de fragancia','Pais de origen','Ingredientes destacados','Certificaciones','Contenido del paquete','Peso','Garantia'],
    paletaVariante: ['Volumen','Color'],
    productos: [
      { nombre: 'Eau de parfum Bruma', precio: 720,
        descripcion: 'Salida citrica, fondo amaderado, doce horas de fijacion.',
        car: { Marca:'Bruma', 'Tipo de fragancia':'Amaderada citrica', 'Pais de origen':'Francia', 'Ingredientes destacados':['Bergamota','Cedro','Vetiver'] },
        variantes: [
          { nombre:'50 ml', factor:1.00, car:{ Volumen:50 } },
          { nombre:'100 ml', factor:1.62, car:{ Volumen:100 } },
        ] },
      { nombre: 'Eau de toilette Salino', precio: 480,
        descripcion: 'Salida de sal marina y salvia, con estela fresca de unas seis horas.',
        car: { Marca:'Salino', 'Tipo de fragancia':'Acuatica fresca', 'Pais de origen':'Espana', 'Ingredientes destacados':['Sal marina','Salvia','Ambar blanco'] },
        variantes: [
          { nombre:'30 ml', factor:1.00, car:{ Volumen:30 } },
          { nombre:'60 ml', factor:1.48, car:{ Volumen:60 } },
          { nombre:'100 ml', factor:1.85, car:{ Volumen:100, Color:'Vidrio azul' } },
        ] },
      { nombre: 'Agua de colonia Amanecer Citrico', precio: 290,
        descripcion: 'Colonia citrica de uso diario, ligera y sin fondo dulce.',
        car: { Marca:'Amanecer', 'Tipo de fragancia':'Citrica fresca', Certificaciones:['Vegano','No testeado en animales'], 'Contenido del paquete':['Frasco','Atomizador de repuesto'], Peso:0.34 },
        variantes: [
          { nombre:'100 ml', factor:1.00, car:{ Volumen:100, Color:'Vidrio ambar' } },
          { nombre:'200 ml', factor:1.68, car:{ Volumen:200, Color:'Vidrio ambar' } },
        ] },
      { nombre: 'Bruma corporal Trebol Blanco', precio: 165,
        descripcion: 'Bruma ligera para el cuerpo y la ropa, floral y de poca fijacion.',
        car: { Marca:'Trebol', 'Tipo de fragancia':'Floral verde', 'Pais de origen':'Guatemala', 'Ingredientes destacados':['Trebol','Almizcle blanco'], 'Contenido del paquete':['Frasco con atomizador'] },
        variantes: [
          { nombre:'200 ml', factor:1.00, car:{ Volumen:200 } },
        ] },
      { nombre: 'Set descubrimiento Nocturno', precio: 390,
        descripcion: 'Cuatro viales de 8 ml para probar la linea antes de comprar el frasco.',
        car: { Marca:'Nocturno', 'Tipo de fragancia':'Oriental amaderada', Certificaciones:['Cruelty free'], 'Contenido del paquete':['Cuatro viales de 8 ml','Tarjeta de notas olfativas'], Peso:0.18, Garantia:6 },
        variantes: [
          { nombre:'Coleccion noche', factor:1.00, car:{ Color:'Estuche negro' } },
          { nombre:'Coleccion dia', factor:1.12, car:{ Color:'Estuche marfil' } },
        ] },
    ] },
] },
];


// ============================================================
// Lo que cambio con el tiempo
// ============================================================
// Sin esto, el historial de cada producto tendria una sola fila y la coleccion
// de eventos saldria con puras creaciones: la reconstruccion por fecha
// existiria pero no habria nada que ensenar con ella.
//
// Cada entrada es como estaba el producto ANTES, con la fecha desde la que
// regia esa version. Lo que no se nombra se hereda de la entrada anterior, y
// la ultima version es siempre la fila viva. Se escribe a mano y no al azar:
// que cambio es contenido, no reparto.
const HISTORIA = {
  'Camisa de lino manga larga': [
    { fecha: '2026-01-12 09:00:00-06', nombre: 'Camisa de lino', descripcion: 'Camisa de lino de corte regular.' },
    { fecha: '2026-03-04 11:30:00-06', descripcion: 'Lino lavado de corte regular con cuello italiano.' },
  ],
  'Laptop Aurora 14': [
    { fecha: '2026-01-04 10:52:00-06', descripcion: 'Ultraligera de 14 pulgadas.' },
    { fecha: '2026-02-18 15:00:00-06', nombre: 'Laptop Aurora 14 (2026)' },
  ],
  'Telefono Vela 7': [
    { fecha: '2026-01-24 10:15:00-06', nombre: 'Telefono Vela 7 Plus', descripcion: 'Pantalla OLED de 6.4 pulgadas.' },
  ],
  'Balon de futbol numero 5': [
    // Nacio mal clasificado, en Fitness, y se movio a Futbol. Es el caso que
    // justifica id_categoria en productos_historial: sin esa columna, mover el
    // producto reescribiria su pasado y la reconstruccion de enero contestaria
    // con la categoria de hoy.
    { fecha: '2026-04-06 08:00:00-06', hoja: 'Fitness' },
  ],
  'Cafetera Alba Espresso': [
    { fecha: '2026-02-08 12:00:00-06', descripcion: 'Cafetera de brazo con vaporizador.' },
  ],
  'El camino de las nubes': [
    { fecha: '2026-05-20 09:00:00-06', nombre: 'El camino de las nubes (primera edicion)' },
  ],
};

// Variantes que se renombraron. Mismo criterio.
const HISTORIA_VARIANTE = {
  'Camisa de lino manga larga|M azul': [
    { fecha: '2026-01-12 09:00:00-06', nombre_variante: 'Mediana azul' },
  ],
  'Laptop Aurora 14|16 GB / 512 GB': [
    { fecha: '2026-01-04 10:52:00-06', nombre_variante: '16 GB' },
  ],
};


// ============================================================
// Imagenes
// ============================================================
// Una por producto, TODAS comprobadas: codigo 200, content-type de imagen
// y mas de 8 KB, verificadas dos veces (al buscarlas y otra vez en frio).
//
// Salen de la API de Wikimedia Commons, que devuelve la url de miniatura ya
// armada. NO se escriben a mano: la tanda anterior se armo adivinando el
// nombre del archivo y 4 de sus 7 urls daban 404 -- un 404 de Wikimedia
// devuelve una pagina HTML, asi que el <img> se queda con el icono roto y
// desde el navegador se lee igual que un fallo de la tienda.
//
// Wikimedia solo genera miniaturas con anchos de una lista fija (960 si,
// 800 no) y corta por ritmo con 429 si se le piden muchas de golpe.
const IMAGENES = {
  'Laptop Aurora 14':                                ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/37/Schenker_VIA14_Laptop_asv2021-01.jpg/960px-Schenker_VIA14_Laptop_asv2021-01.jpg'],
  'Laptop Bastion 16':                               ['https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/Lenovo_G500s_laptop-2903.jpg/960px-Lenovo_G500s_laptop-2903.jpg'],
  'Laptop Nimbo 13':                                 ['https://upload.wikimedia.org/wikipedia/commons/thumb/5/53/Asus_x21_ultrabook.jpg/960px-Asus_x21_ultrabook.jpg'],
  'Laptop Lienzo 15':                                ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/2-in-1_laptop.jpeg/960px-2-in-1_laptop.jpeg'],
  'Laptop Cumbre 17 Gamer':                          ['https://upload.wikimedia.org/wikipedia/commons/e/ef/Dell.._Laptop.jpg'],
  'Laptop Vireo Air 12':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/Laptop%2C_Small_notebook%2C_Netbook%2C_Rostov-on-Don%2C_Russia.jpg/960px-Laptop%2C_Small_notebook%2C_Netbook%2C_Rostov-on-Don%2C_Russia.jpg'],
  'Laptop Ambar Campus 14':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png/960px-Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png'],
  'Telefono Vela 7':                                 ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg'],
  'Telefono Ceibo Lite':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/68/HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg/960px-HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg'],
  'Telefono Nautilo Pro':                            ['https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg/960px-T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg'],
  'Telefono Pedernal Rugged':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg'],
  'Telefono Bruma Mini':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/9/96/Smartphone_being_charged.jpg/960px-Smartphone_being_charged.jpg'],
  'Telefono Cuarzo Duo':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/38/EMOBILE_LTE_phone_in_Japan.jpg/960px-EMOBILE_LTE_phone_in_Japan.jpg'],
  'Audifonos Sereno ANC':                            ['https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg/960px-Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg'],
  'Audifonos Brisa Sport':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/73/Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg/960px-Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg'],
  'Audifonos Estudio 900':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/a6/Studio_Headphones.jpg/960px-Studio_Headphones.jpg'],
  'Audifonos Colibri Micro TWS':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Beige_Earphones.jpg/960px-Beige_Earphones.jpg'],
  'Audifonos Marea Diadema Abierta':                 ['https://upload.wikimedia.org/wikipedia/commons/6/63/Headphones_on_white_background.jpg'],
  'Audifonos Duna Trabajo':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Headphones_1.jpg/960px-Headphones_1.jpg'],
  'Audifonos Zumbo Cable':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/1d/Earphones_BW_2011-12-10_15-49-08.JPG/960px-Earphones_BW_2011-12-10_15-49-08.JPG'],
  'Monitor Horizonte 27':                            ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Dell_Professional_P2212H-9899.jpg/960px-Dell_Professional_P2212H-9899.jpg'],
  'Monitor Panorama 34':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/e/e4/Monitor_ultrawide_21_9.jpg/960px-Monitor_ultrawide_21_9.jpg'],
  'Monitor Vitral 24':                               ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Computer_monitor.jpg/960px-Computer_monitor.jpg'],
  'Monitor Cenit 32 4K':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/f/f3/Computer_monitor_screen_image_simulated.jpg/960px-Computer_monitor_screen_image_simulated.jpg'],
  'Monitor Vertice 27 Gamer':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png'],
  'Monitor Nube 22':                                 ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/NEC_MONITOR_E2206XG.jpg/960px-NEC_MONITOR_E2206XG.jpg'],
  'Cafetera Alba Espresso':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/7f/A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg/960px-A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg'],
  'Juego de ollas Fuego 5 piezas':                   ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/13/All-Clad_Copper_Core_pots.jpeg/960px-All-Clad_Copper_Core_pots.jpeg'],
  'Licuadora Torbellino 1200':                       ['https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/BL807_Red-4_in_1.jpg/960px-BL807_Red-4_in_1.jpg'],
  'Hervidor electrico Vapor 1.7':                    ['https://upload.wikimedia.org/wikipedia/commons/thumb/5/51/HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg/960px-HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg'],
  'Cacerola honda Comal 18':                         ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/65/Hahn_16cm_Saucepan.jpg/960px-Hahn_16cm_Saucepan.jpg'],
  'Olla arrocera Grano 8 tazas':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/62/Zojirushi_Rice_Cooker_NP-RG05.jpg/960px-Zojirushi_Rice_Cooker_NP-RG05.jpg'],
  'Tabla de picar Cedro grande':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/48/Cutting_Board.jpg/960px-Cutting_Board.jpg'],
  'Escritorio Roble 120':                            ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/Bureau_table_%28desk%29_MET_DP-14204-114.jpg/960px-Bureau_table_%28desk%29_MET_DP-14204-114.jpg'],
  'Silla ergonomica Vertebra':                       ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Prototype_ergonomic_office_chair%2C_V%26A_London.jpg/960px-Prototype_ergonomic_office_chair%2C_V%26A_London.jpg'],
  'Librero Hoja 5 niveles':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Bookcase_MET_240710.jpg/960px-Bookcase_MET_240710.jpg'],
  'Mesa de centro Guijarro':                         ['https://upload.wikimedia.org/wikipedia/commons/a/a0/Carleson_Solid_Wood_Coffee_Table_In_Provincial_Tea_%28264060733%29.jpeg'],
  'Silla de comedor Vara':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/e/e3/Wooden_Dining_Chair.jpg/960px-Wooden_Dining_Chair.jpg'],
  'Comoda Sendero 4 gavetas':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/5/59/A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg/960px-A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg'],
  'Lampara de escritorio Faro':                      ['https://upload.wikimedia.org/wikipedia/commons/thumb/b/bf/Desktop-lamp-2_hg.jpg/960px-Desktop-lamp-2_hg.jpg'],
  'Tira LED Aurora 5 m':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Light_blue_LED_strip.jpg/960px-Light_blue_LED_strip.jpg'],
  'Lampara colgante Candela 40':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Geometric_white_pendant_lamp_chandelier.jpg/960px-Geometric_white_pendant_lamp_chandelier.jpg'],
  'Lampara de pie Vigia 165':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Floor_lamp_1_2016-07-06.jpg/960px-Floor_lamp_1_2016-07-06.jpg'],
  'Plafon LED Solaz 24':                             ['https://upload.wikimedia.org/wikipedia/commons/4/45/Led_wohnraumleuchte.jpg'],
  'Farol solar de jardin Luciernaga':                ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/ad/Solar_garden_light.jpg/960px-Solar_garden_light.jpg'],
  'Camisa de lino manga larga':                      ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Button_down_dress_shirts_for_men.jpg/960px-Button_down_dress_shirts_for_men.jpg'],
  'Camisa oxford clasica':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg/960px-Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg'],
  'Camisa guayabera Xelaju':                         ['https://upload.wikimedia.org/wikipedia/commons/9/9d/Guayabera_de_Lino_Keten.jpg'],
  'Camisa de vestir Meridiano':                      ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Camisade_pu%C3%B1o_doble.jpg/960px-Camisade_pu%C3%B1o_doble.jpg'],
  'Camisa de mezclilla Remache':                     ['https://upload.wikimedia.org/wikipedia/commons/e/ec/Man_wearing_blue_denim_shirt_with_rolled_sleeves%2C_tan_chinos_1.jpg'],
  'Camisa polo pique Cardumen':                      ['https://upload.wikimedia.org/wikipedia/commons/thumb/d/d1/Various_colors_of_polo_shirt_at_JCPenney.jpg/960px-Various_colors_of_polo_shirt_at_JCPenney.jpg'],
  'Pantalon chino resistente':                       ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Chino_pants.jpg/960px-Chino_pants.jpg'],
  'Pantalon de mezclilla Yunque':                    ['https://upload.wikimedia.org/wikipedia/commons/d/d2/Jeans_for_men.jpg'],
  'Pantalon cargo Vereda':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Cargo_pants_001.jpg/960px-Cargo_pants_001.jpg'],
  'Pantalon de vestir Consulado':                    ['https://upload.wikimedia.org/wikipedia/commons/f/fb/Trousers.jpg'],
  'Pantalon jogger Ocaso':                           ['https://upload.wikimedia.org/wikipedia/commons/c/c3/Sweatpants.jpg'],
  'Zapato de cuero Senda':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Mens_brown_derby_leather_shoes.jpg/960px-Mens_brown_derby_leather_shoes.jpg'],
  'Bota impermeable Cumbre':                         ['https://upload.wikimedia.org/wikipedia/commons/thumb/2/29/Hiking_shoes_Lowa.jpg/960px-Hiking_shoes_Lowa.jpg'],
  'Tenis urbano Vereda 90':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/43/Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg/960px-Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg'],
  'Mocasin de gamuza Roble':                         ['https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Handmade_Lake_Blue_Loafers_Shoe.jpg/960px-Handmade_Lake_Blue_Loafers_Shoe.jpg'],
  'Bota de trabajo Yunque S3':                       ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg'],
  'Sandalia de cuero Litoral':                       ['https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Leather_sandals.jpg/960px-Leather_sandals.jpg'],
  'Balon de futbol numero 5':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/Ball_white_black.jpg/960px-Ball_white_black.jpg'],
  'Espinilleras Muralla':                            ['https://upload.wikimedia.org/wikipedia/commons/0/0e/Shinpads.jpg'],
  'Guantes de portero Zarpa 300':                    ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Guanti_da_portiere.jpg/960px-Guanti_da_portiere.jpg'],
  'Zapato de tacos Relampago FG':                    ['https://upload.wikimedia.org/wikipedia/commons/thumb/e/e1/Football_boots_%283293104040%29.jpg/960px-Football_boots_%283293104040%29.jpg'],
  'Red de porteria Trama 7 x 2':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/9/9c/Football_goal_net.jpg/960px-Football_goal_net.jpg'],
  'Uniforme de entrenamiento Cantera':               ['https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Football_kit_01.jpg/960px-Football_kit_01.jpg'],
  'Casco de ruta Aerodino':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/81/Bicycle_Helmet_0085_Transparent.png/960px-Bicycle_Helmet_0085_Transparent.png'],
  'Bomba de piso Piston':                            ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/SKS_Rennkompressor_Standpumpe.jpg/960px-SKS_Rennkompressor_Standpumpe.jpg'],
  'Guantes de ciclismo Palma Corta':                 ['https://upload.wikimedia.org/wikipedia/commons/d/d0/Bicycle_glove.jpg'],
  'Sillin de ruta Vertebra SR-2':                    ['https://upload.wikimedia.org/wikipedia/commons/thumb/2/25/Road_bike_saddle1.jpg/960px-Road_bike_saddle1.jpg'],
  'Maillot de ruta Peloton':                         ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/020230923_cycling_jerseys_for_men.jpg/960px-020230923_cycling_jerseys_for_men.jpg'],
  'Candado plegable Cerrojo F8':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Folding_bike_lock.jpg/960px-Folding_bike_lock.jpg'],
  'Set de bandas elasticas':                         ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Grid_Layout_of_Blue_Barry%27s_Exercise_Mats_and_Resistance_Bands.jpg/960px-Grid_Layout_of_Blue_Barry%27s_Exercise_Mats_and_Resistance_Bands.jpg'],
  'Tapete de yoga Raiz 6 mm':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Yoga_mat.jpg/960px-Yoga_mat.jpg'],
  'Mancuernas ajustables Vertice 20 kg':             ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Aluminium_Dumbbell.jpg/960px-Aluminium_Dumbbell.jpg'],
  'Pesa rusa Yunque':                                ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Competition_kettlebell_16_kilo.jpg/960px-Competition_kettlebell_16_kilo.jpg'],
  'Cuerda de salto Relampago':                       ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/8b/Exercise_equipment_%28rubber_ball%2C_light-weight_dumbbells%2C_jump_rope%29.jpg/960px-Exercise_equipment_%28rubber_ball%2C_light-weight_dumbbells%2C_jump_rope%29.jpg'],
  'Rodillo de liberacion Nudo':                      ['https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/Hartschaumrolle.jpg/960px-Hartschaumrolle.jpg'],
  'El camino de las nubes':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Aufgeschlagenes_Buch_--_2020_--_4204.jpg/960px-Aufgeschlagenes_Buch_--_2020_--_4204.jpg'],
  'Cuentos de la ceiba':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Old_Books_01.JPG/960px-Old_Books_01.JPG'],
  'La casa de los relojes detenidos':                ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/6c/Books_in_stack_with_lamps_%28Unsplash%29.jpg/960px-Books_in_stack_with_lamps_%28Unsplash%29.jpg'],
  'Cartas al puerto seco':                           ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/1c/Old_books_%28Unsplash%29.jpg/960px-Old_books_%28Unsplash%29.jpg'],
  'Nadie duerme en Tecpanal':                        ['https://upload.wikimedia.org/wikipedia/commons/thumb/d/dc/Old_Books_04.JPG/960px-Old_Books_04.JPG'],
  'Antologia del ruido':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg/960px-Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg'],
  'Bases de datos distribuidas':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/c6/The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg/960px-The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg'],
  'Redes industriales y buses de campo':             ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/8c/Reference_books_on_shelf_01.jpg/960px-Reference_books_on_shelf_01.jpg'],
  'Calculo numerico con ejercicios resueltos':       ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/af/Reference_books_on_shelf_02.jpg/960px-Reference_books_on_shelf_02.jpg'],
  'Manual de instalaciones electricas residenciales': ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Nuevos_libros_de_texto_gratuitos.jpg/960px-Nuevos_libros_de_texto_gratuitos.jpg'],
  'Introduccion al modelado de sistemas embebidos':  ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg/960px-Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg'],
  'Serum de niacinamida 10%':                        ['https://upload.wikimedia.org/wikipedia/commons/9/94/2_oz_-_60_ml_Amber_Glass_Boston_Round_Bottles_with_Gold_Metal_and_Glass_Droppers.jpg'],
  'Protector solar mineral FPS 50':                  ['https://upload.wikimedia.org/wikipedia/commons/thumb/b/bd/LRP_sunscreen_bottle.jpg/960px-LRP_sunscreen_bottle.jpg'],
  'Crema hidratante nocturna Alba':                  ['https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Day_cream_02.jpg/960px-Day_cream_02.jpg'],
  'Limpiador en gel Verdo':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/2/27/Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG/960px-Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG'],
  'Exfoliante enzimatico Papilo':                    ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Exfoliating_face_scrub.jpg/960px-Exfoliating_face_scrub.jpg'],
  'Contorno de ojos Lumine':                         ['https://upload.wikimedia.org/wikipedia/commons/f/fc/Under_eye_cream.jpg'],
  'Eau de parfum Bruma':                             ['https://upload.wikimedia.org/wikipedia/commons/thumb/e/ef/MOI_Fragrances_Bottle.jpg/960px-MOI_Fragrances_Bottle.jpg'],
  'Eau de toilette Salino':                          ['https://upload.wikimedia.org/wikipedia/commons/thumb/7/79/Perfume_glass_bottle.jpg/960px-Perfume_glass_bottle.jpg'],
  'Agua de colonia Amanecer Citrico':                ['https://upload.wikimedia.org/wikipedia/commons/thumb/a/a1/Czech_Glass_Perfume_Bottle-2.jpg/960px-Czech_Glass_Perfume_Bottle-2.jpg'],
  'Bruma corporal Trebol Blanco':                    ['https://upload.wikimedia.org/wikipedia/commons/thumb/d/db/Bottles_of_Eau_de_Toilette.jpg/960px-Bottles_of_Eau_de_Toilette.jpg'],
  'Set descubrimiento Nocturno':                     ['https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Perfume_set_from_Sovjetunio_cca_1965.jpg/960px-Perfume_set_from_Sovjetunio_cca_1965.jpg'],
};


// ============================================================
// Utilidades de SQL
// ============================================================
const txt = (v) => (v === null || v === undefined ? 'NULL' : `'${String(v).replace(/'/g, "''")}'`);
const num = (v) => (v === null || v === undefined ? 'NULL' : String(v));
const bool = (v) => (v ? 'true' : 'false');

// El valor de una caracteristica se guarda SIEMPRE como texto: tipo_dato dice
// como leerlo. Una lista son varias filas con el mismo nombre.
function valorATexto(v) {
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return String(v);
}

const L = [];
const w = (s) => L.push(s);


// ============================================================
// Cabecera
// ============================================================
w(`-- 001_catalogo.sql`);
w(`-- GENERADO por migrations/datos/generador.js. No editar a mano: la proxima`);
w(`-- corrida del generador lo reescribe. Para cambiar algo, se cambia el`);
w(`-- generador y se vuelve a correr.`);
w(`--`);
w(`--   node migrations/datos/generador.js`);
w(`--`);
w(`-- Que trae, y por que esta armado asi:`);
w(`--`);
w(`--   * El catalogo es COMPARTIDO. Un producto no es de nadie: describe una`);
w(`--     cosa. Quien la vende y a como es una fila de oferta.`);
w(`--   * La cuenta de la tienda (tienda@mesh.com) tiene oferta de TODAS las`);
w(`--     variantes, y su precio es el que se ensena en la pagina.`);
w(`--   * Los otros cuatro vendedores ofertan un subconjunto, repartido con una`);
w(`--     semilla fija: asi hay productos con un solo precio y otros con cinco.`);
w(`--   * Ningun id va a mano. Todo se busca por nombre o por correo, porque un`);
w(`--     id escrito a mano corre en una maquina y revienta en la de al lado.`);
w(``);
w(``);
w(`-- ============================================================`);
w(`-- Por que se apaga un trigger a la mitad`);
w(`-- ============================================================`);
w(`-- El trigger del 005 escribe una fila de precio_historial cada vez que nace`);
w(`-- o cambia una oferta, y le pone now(). Eso es lo correcto para la`);
w(`-- aplicacion, pero este conjunto de datos necesita fechas del PASADO: sin`);
w(`-- ellas no habria nada que reconstruir y la Entrega 1 se quedaria sin su`);
w(`-- demostracion.`);
w(`--`);
w(`-- Asi que las filas de precio se escriben a mano, con sus fechas, y el`);
w(`-- trigger se apaga mientras tanto. Se vuelve a encender al final, y al final`);
w(`-- tambien se comprueba que el saldo de cada oferta cuadre con su kardex.`);
w(``);
w(`BEGIN;`);
w(``);
w(`ALTER TABLE oferta DISABLE TRIGGER trg_oferta_registrar_precio;`);
w(``);


// ============================================================
// Usuarios
// ============================================================
w(`-- ============================================================`);
w(`-- Las cuentas`);
w(`-- ============================================================`);
w(`-- Contrasenas: Vendedor123 para la tienda y los cuatro vendedores,`);
w(`-- Comprador123 para los compradores, Admin123 para el admin. Son hashes de`);
w(`-- scrypt en formato salt:hash, el mismo que usa el backend.`);
w(`--`);
w(`-- NOT EXISTS sobre las DOS restricciones unicas de usuarios, no solo sobre`);
w(`-- el correo: si alguien ya se registro con ese nombre de usuario, un`);
w(`-- ON CONFLICT (correo_electronico) revienta igual.`);
w(``);
w(`INSERT INTO usuarios (correo_electronico, usuario, nombre, apellido, contrasena_hash, id_rol_usuario, id_estado_usuario)`);
w(`SELECT v.correo, v.usuario, v.nombre, v.apellido, v.clave, r.id_rol_usuario, e.id_estado_usuario`);
w(`FROM (VALUES`);
w(USUARIOS.map((u, i) =>
  `    (${txt(u.correo)}, ${txt(u.usuario)}, ${txt(u.nombre)}, ${txt(u.apellido)}, ${txt(u.clave)}, ${txt(u.rol)})` +
  (i < USUARIOS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(correo, usuario, nombre, apellido, clave, rol)`);
w(`JOIN rol_usuario    r ON r.rol_usuario_nombre    = v.rol`);
w(`JOIN estado_usuario e ON e.estado_usuario_nombre = 'activo'`);
w(`WHERE NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.correo_electronico = v.correo)`);
w(`  AND NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.usuario            = v.usuario);`);
w(``);

// Direcciones de los compradores: hacen falta para poder crear un pedido
w(`-- Las direcciones de los compradores. Sin una direccion no se puede crear`);
w(`-- un pedido: crear_pedido pide su id_direccion_historial.`);
// La calle (direccion_exacta, migracion 008) va AQUI y no en un UPDATE aparte:
// el esquema corre antes que los datos, asi que cuando la 008 anade la columna
// esta tabla todavia esta vacia y no hay nada que rellenar. Si la calle no
// naciera en este INSERT, una base recien cargada quedaria con las dos
// direcciones sin calle -- y el backend la exige al crear una nueva, o sea que
// los datos de prueba serian los unicos que no cumplen su propia regla.
//
// Y va emparejada por CORREO, no por id. Es la regla de migrations/README.md y
// aqui se ve para que sirve: la calle de Antigua tiene que caerle al comprador
// del sur y la de la zona 10 a la compradora del norte. Emparejarlas por
// id_direccion las cruza sin que nada falle.
w(`INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, id_estado_direccion)`);
w(`SELECT u.id_usuario, v.pais, v.departamento, v.ciudad, v.calle, v.codigo, ed.id_estado_direccion`);
w(`FROM (VALUES`);
w(`    ('compradora.norte@mesh.com', 'Guatemala', 'Guatemala',     'Guatemala',         '6a. Avenida 9-18, Zona 10, Edificio Vista Real, Nivel 3', '01010'),`);
w(`    ('comprador.sur@mesh.com',    'Guatemala', 'Sacatepequez',  'Antigua Guatemala', '5a. Avenida Norte 22, frente al Arco de Santa Catalina',   '03001')`);
w(`) AS v(correo, pais, departamento, ciudad, calle, codigo)`);
w(`JOIN usuarios u ON u.correo_electronico = v.correo`);
w(`JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa'`);
w(`WHERE NOT EXISTS (SELECT 1 FROM direcciones d WHERE d.id_usuario = u.id_usuario);`);
w(``);
w(`-- Su primera version en el historial. El pedido apunta AQUI y no a`);
w(`-- direcciones: guarda a donde se mando de verdad, aunque despues la editen.`);
w(`-- La calle se copia igual que el resto: si faltara aqui, la etiqueta de un`);
w(`-- pedido viejo se quedaria sin ella.`);
w(`INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal)`);
w(`SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.direccion_exacta, d.codigo_postal`);
w(`FROM direcciones d`);
w(`WHERE NOT EXISTS (SELECT 1 FROM direccion_historial h WHERE h.id_direccion = d.id_direccion);`);
w(``);


// ============================================================
// Categorias
// ============================================================
w(`-- ============================================================`);
w(`-- Las categorias: dos niveles`);
w(`-- ============================================================`);
w(`-- Las raices primero, porque las hojas las referencian. Una raiz agrupa y`);
w(`-- no lleva nada: ni caracteristicas ni productos. Lo garantizan los dos`);
w(`-- triggers del 003.`);
w(``);
w(`INSERT INTO categorias (nombre, id_categoria_padre) VALUES`);
w(CATALOGO.map((g, i) => `    (${txt(g.raiz)}, NULL)` + (i < CATALOGO.length - 1 ? ',' : ';')).join('\n'));
w(``);
w(`INSERT INTO categorias (nombre, id_categoria_padre)`);
w(`SELECT v.hoja, p.id_categoria`);
w(`FROM (VALUES`);
const filasHojas = [];
CATALOGO.forEach((g) => g.hojas.forEach((h) => filasHojas.push(`    (${txt(h.nombre)}, ${txt(g.raiz)})`)));
w(filasHojas.join(',\n'));
w(`) AS v(hoja, raiz)`);
w(`JOIN categorias p ON p.nombre = v.raiz AND p.id_categoria_padre IS NULL;`);
w(``);


// ============================================================
// Definiciones de caracteristica
// ============================================================
w(`-- ============================================================`);
w(`-- Las definiciones de caracteristica`);
w(`-- ============================================================`);
w(`-- Se definen una vez y las usan muchas categorias. La unidad va en la`);
w(`-- definicion y no en cada valor: asi el valor queda limpio (16, no "16 GB")`);
w(`-- y se puede comparar y ordenar como numero.`);
w(``);
w(`INSERT INTO caracteristica (nombre, id_tipo_dato, unidad)`);
w(`SELECT v.nombre, t.id_tipo_dato, v.unidad`);
w(`FROM (VALUES`);
w(CARACTERISTICAS.map(([n, t, u], i) =>
  `    (${txt(n)}, ${txt(t)}, ${u ? txt(u) : 'NULL'})` + (i < CARACTERISTICAS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(nombre, tipo, unidad)`);
w(`JOIN tipo_dato t ON t.tipo_dato = v.tipo;`);
w(``);
w(`INSERT INTO caracteristica_variante (nombre, id_tipo_dato, unidad)`);
w(`SELECT v.nombre, t.id_tipo_dato, v.unidad`);
w(`FROM (VALUES`);
w(CARACTERISTICAS_VARIANTE.map(([n, t, u], i) =>
  `    (${txt(n)}, ${txt(t)}, ${u ? txt(u) : 'NULL'})` + (i < CARACTERISTICAS_VARIANTE.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(nombre, tipo, unidad)`);
w(`JOIN tipo_dato t ON t.tipo_dato = v.tipo;`);
w(``);


// ============================================================
// Paletas por categoria hoja
// ============================================================
w(`-- ============================================================`);
w(`-- Que ofrece cada hoja`);
w(`-- ============================================================`);
w(`-- Esto arma el formulario de publicar. NO dice que tiene un producto: de lo`);
w(`-- que la categoria ofrece, casi nadie llena todo, y esa es justamente la`);
w(`-- heterogeneidad que la Entrega 1 tiene que ensenar.`);
w(``);
const filasPaleta = [];
const filasPaletaVar = [];
CATALOGO.forEach((g) => g.hojas.forEach((h) => {
  h.paleta.forEach((c) => filasPaleta.push(`    (${txt(h.nombre)}, ${txt(c)})`));
  h.paletaVariante.forEach((c) => filasPaletaVar.push(`    (${txt(h.nombre)}, ${txt(c)})`));
}));
w(`INSERT INTO categoria_caracteristica (id_categoria, id_caracteristica)`);
w(`SELECT c.id_categoria, k.id_caracteristica`);
w(`FROM (VALUES`);
w(filasPaleta.join(',\n'));
w(`) AS v(hoja, caracteristica)`);
w(`JOIN categorias      c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL`);
w(`JOIN caracteristica  k ON k.nombre = v.caracteristica;`);
w(``);
w(`INSERT INTO categoria_caracteristica_variante (id_categoria, id_caracteristica_variante)`);
w(`SELECT c.id_categoria, k.id_caracteristica`);
w(`FROM (VALUES`);
w(filasPaletaVar.join(',\n'));
w(`) AS v(hoja, caracteristica)`);
w(`JOIN categorias             c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL`);
w(`JOIN caracteristica_variante k ON k.nombre = v.caracteristica;`);
w(``);


// ============================================================
// Productos y variantes
// ============================================================
// Fechas escalonadas: el catalogo no nacio todo el mismo dia, y el historial
// necesita un pasado para poder reconstruirlo.
const PRODUCTOS = [];
CATALOGO.forEach((g) => g.hojas.forEach((h) => h.productos.forEach((p) => {
  PRODUCTOS.push({ ...p, hoja: h.nombre, raiz: g.raiz, paleta: h.paleta, paletaVariante: h.paletaVariante });
})));

// Un dia distinto por producto, empezando en enero y avanzando de a poco.
//
// El PASO SE CALCULA, no es fijo. Antes era `3 + i * 5` y funcionaba por
// casualidad: con 34 productos el ultimo caia en julio, pero al pasar a 102 el
// mismo calculo daba "2026-19-05" y PostgreSQL rechazaba la carga ENTERA con
// "date/time field value out of range". Un dato de prueba que revienta al
// crecer no es un dato de prueba.
//
// El tope son 6 meses y no 12 a proposito: los cambios de precio y las
// versiones del historial se colocan 2 meses DESPUES del nacimiento, acotados
// con Math.min(8) y Math.min(9). Si los productos llegaran a noviembre, esos
// topes los dejarian ANTES de que el producto existiera, y el historial
// quedaria al reves sin que nada avisara.
const MES_TOPE = 6;
const paso = Math.max(1, Math.floor((MES_TOPE * 28 - 3) / Math.max(1, PRODUCTOS.length)));

PRODUCTOS.forEach((p, i) => {
  const dia = 3 + i * paso;
  const mes = 1 + Math.floor(dia / 28);
  const d = 1 + (dia % 28);
  p.fecha = `2026-${String(mes).padStart(2, '0')}-${String(d).padStart(2, '0')} 10:${String(entre(0, 59)).padStart(2, '0')}:00-06`;

  // Si el producto tiene historia, nace en la fecha de su primera version. El
  // ETL toma la primera fila del historial como el nacimiento; si no
  // coincidieran, el primer evento quedaria fuera de rango y se perderia.
  const h = HISTORIA[p.nombre];
  if (h && h.length > 0) p.fecha = h[0].fecha;
});

// Las filas del historial de un producto: sus versiones anteriores y, al
// final, la viva. Lo que una version no nombra se hereda de la anterior.
function filasHistorial(p) {
  const h = HISTORIA[p.nombre] || [];
  const filas = [];
  let estado = { nombre: p.nombre, descripcion: p.descripcion, hoja: p.hoja };

  if (h.length === 0) {
    return [{ fecha: p.fecha, ...estado }];
  }

  h.forEach((paso, i) => {
    estado = { ...estado, ...paso };
    delete estado.fecha;
    // La primera version rige desde que nacio el producto
    filas.push({ fecha: i === 0 ? p.fecha : paso.fecha, ...estado });
  });

  // Y la version de hoy, dos meses despues de la ultima
  const ultima = h[h.length - 1].fecha;
  const mes = Math.min(9, Number(ultima.slice(5, 7)) + 2);
  filas.push({
    fecha: `2026-${String(mes).padStart(2, '0')}-${ultima.slice(8, 10)} 14:00:00-06`,
    nombre: p.nombre, descripcion: p.descripcion, hoja: p.hoja,
  });

  return filas;
}

function filasHistorialVariante(v) {
  const h = HISTORIA_VARIANTE[v.producto + '|' + v.nombre] || [];
  const filas = [];
  let estado = { nombre_variante: v.nombre, descripcion: v.descripcion || null };

  if (h.length === 0) {
    return [{ fecha: v.fecha, ...estado }];
  }

  h.forEach((paso, i) => {
    estado = { ...estado, ...paso };
    delete estado.fecha;
    filas.push({ fecha: i === 0 ? v.fecha : paso.fecha, ...estado });
  });

  const ultima = h[h.length - 1].fecha;
  const mes = Math.min(9, Number(ultima.slice(5, 7)) + 2);
  filas.push({
    fecha: `2026-${String(mes).padStart(2, '0')}-${ultima.slice(8, 10)} 14:00:00-06`,
    nombre_variante: v.nombre, descripcion: v.descripcion || null,
  });

  return filas;
}

w(`-- ============================================================`);
w(`-- Los productos: ${PRODUCTOS.length} en ${filasHojas.length} categorias hoja`);
w(`-- ============================================================`);
w(`-- Cuelgan de una hoja, nunca de una raiz. Las fechas estan escalonadas a lo`);
w(`-- largo del ano: sin un pasado no hay nada que reconstruir.`);
w(``);
w(`INSERT INTO productos (nombre, descripcion, fecha_creacion, id_estado_producto, id_categoria)`);
w(`SELECT v.nombre, v.descripcion, v.fecha::timestamptz, ep.id_estado_producto, c.id_categoria`);
w(`FROM (VALUES`);
w(PRODUCTOS.map((p, i) =>
  `    (${txt(p.nombre)}, ${txt(p.descripcion)}, ${txt(p.fecha)}, ${txt(p.hoja)})` +
  (i < PRODUCTOS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(nombre, descripcion, fecha, hoja)`);
w(`JOIN estado_producto ep ON ep.estado_producto_nombre = 'activo'`);
w(`JOIN categorias      c  ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;`);
w(``);

const VARIANTES = [];
PRODUCTOS.forEach((p) => p.variantes.forEach((v) => {
  VARIANTES.push({ ...v, producto: p.nombre, fecha: p.fecha, precioBase: p.precio });
}));

w(`-- Las variantes. Son del CATALOGO y no del vendedor: los cinco que venden`);
w(`-- la misma laptop ofertan la misma variante, cada uno con su precio.`);
w(`INSERT INTO productos_variantes (id_producto, nombre_variante, descripcion, fecha_creacion, id_estado_variantes)`);
w(`SELECT p.id_producto, v.nombre_variante, v.descripcion, v.fecha::timestamptz, ev.id_estado_variante`);
w(`FROM (VALUES`);
w(VARIANTES.map((v, i) =>
  `    (${txt(v.producto)}, ${txt(v.nombre)}, ${txt(v.descripcion || null)}, ${txt(v.fecha)})` +
  (i < VARIANTES.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(producto, nombre_variante, descripcion, fecha)`);
w(`JOIN productos       p  ON p.nombre = v.producto`);
w(`JOIN estado_variantes ev ON ev.estado_variante_nombre = 'activa';`);
w(``);


// ============================================================
// La primera foto de cada historial
// ============================================================
w(`-- ============================================================`);
w(`-- La primera version de cada historial`);
w(`-- ============================================================`);
w(`-- Nace con el producto. Sin esta fila, preguntar por una fecha anterior al`);
w(`-- primer CAMBIO contestaria vacio, y "no existia" se leeria igual que`);
w(`-- "nunca cambio".`);
w(``);
const FILAS_HIST = [];
PRODUCTOS.forEach((p) => filasHistorial(p).forEach((f) => FILAS_HIST.push({ producto: p.nombre, ...f })));

const FILAS_HIST_VAR = [];
VARIANTES.forEach((v) => filasHistorialVariante(v).forEach((f) => FILAS_HIST_VAR.push({ producto: v.producto, variante: v.nombre, ...f })));

w(`INSERT INTO productos_historial (id_producto, nombre, descripcion, id_categoria, fecha_creacion)`);
w(`SELECT p.id_producto, v.nombre, v.descripcion, c.id_categoria, v.fecha::timestamptz`);
w(`FROM (VALUES`);
w(FILAS_HIST.map((f, i) =>
  `    (${txt(f.producto)}, ${txt(f.nombre)}, ${txt(f.descripcion)}, ${txt(f.hoja)}, ${txt(f.fecha)})` +
  (i < FILAS_HIST.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(clave, nombre, descripcion, hoja, fecha)`);
w(`JOIN productos  p ON p.nombre = v.clave`);
w(`JOIN categorias c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;`);
w(``);
w(`INSERT INTO productos_variantes_historial (id_producto_variante, nombre_variante, descripcion, fecha_creacion)`);
w(`SELECT pv.id_producto_variante, v.nombre_variante, v.descripcion, v.fecha::timestamptz`);
w(`FROM (VALUES`);
w(FILAS_HIST_VAR.map((f, i) =>
  `    (${txt(f.producto)}, ${txt(f.variante)}, ${txt(f.nombre_variante)}, ${txt(f.descripcion)}, ${txt(f.fecha)})` +
  (i < FILAS_HIST_VAR.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(producto, variante, nombre_variante, descripcion, fecha)`);
w(`JOIN productos           p  ON p.nombre = v.producto`);
w(`JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante;`);
w(``);


// ============================================================
// Valores de caracteristica
// ============================================================
const filasCar = [];
PRODUCTOS.forEach((p) => {
  Object.entries(p.car || {}).forEach(([nombre, valor]) => {
    const lista = Array.isArray(valor) ? valor : [valor];
    lista.forEach((x) => filasCar.push(`    (${txt(p.nombre)}, ${txt(nombre)}, ${txt(valorATexto(x))})`));
  });
});

const filasCarVar = [];
VARIANTES.forEach((v) => {
  Object.entries(v.car || {}).forEach(([nombre, valor]) => {
    const lista = Array.isArray(valor) ? valor : [valor];
    lista.forEach((x) => filasCarVar.push(`    (${txt(v.producto)}, ${txt(v.nombre)}, ${txt(nombre)}, ${txt(valorATexto(x))})`));
  });
});

w(`-- ============================================================`);
w(`-- Los valores: ${filasCar.length} de producto y ${filasCarVar.length} de variante`);
w(`-- ============================================================`);
w(`-- Siempre texto, y sin la unidad. tipo_dato dice como leerlo y el ETL lo`);
w(`-- convierte al tipo real al llevarlo a Mongo. Una caracteristica de tipo`);
w(`-- lista son varias filas con el mismo nombre.`);
w(``);
w(`INSERT INTO producto_caracteristica (id_producto, id_caracteristica, valor)`);
w(`SELECT p.id_producto, k.id_caracteristica, v.valor`);
w(`FROM (VALUES`);
w(filasCar.join(',\n'));
w(`) AS v(producto, caracteristica, valor)`);
w(`JOIN productos      p ON p.nombre = v.producto`);
w(`JOIN caracteristica k ON k.nombre = v.caracteristica;`);
w(``);
w(`INSERT INTO producto_variante_caracteristica_variante (id_producto_variante, id_caracteristica_variante, valor)`);
w(`SELECT pv.id_producto_variante, k.id_caracteristica, v.valor`);
w(`FROM (VALUES`);
w(filasCarVar.join(',\n'));
w(`) AS v(producto, variante, caracteristica, valor)`);
w(`JOIN productos            p  ON p.nombre = v.producto`);
w(`JOIN productos_variantes  pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante`);
w(`JOIN caracteristica_variante k ON k.nombre = v.caracteristica;`);
w(``);


// ============================================================
// Imagenes
// ============================================================
const filasImg = [];
Object.entries(IMAGENES).forEach(([producto, urls]) => {
  const p = PRODUCTOS.find((x) => x.nombre === producto);
  if (!p) return;
  urls.forEach((url) => p.variantes.forEach((v, i) => {
    filasImg.push({ url, producto, variante: v.nombre, orden: 1 });
  }));
});

if (filasImg.length) {
  w(`-- ============================================================`);
  w(`-- Imagenes`);
  w(`-- ============================================================`);
  w(`-- La URL se guarda una vez y se apunta desde cada variante que la usa. Son`);
  w(`-- del catalogo, no del vendedor: los cinco que venden la misma laptop`);
  w(`-- ensenan las mismas fotos, y eso es lo que hace util un catalogo comun.`);
  w(``);
  const urls = [...new Set(filasImg.map((f) => f.url))];
  w(`INSERT INTO imagen_producto (imagen_producto_url) VALUES`);
  w(urls.map((u, i) => `    (${txt(u)})` + (i < urls.length - 1 ? ',' : ';')).join('\n'));
  w(``);
  w(`INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden)`);
  w(`SELECT im.id_imagen_producto, pv.id_producto_variante, v.orden`);
  w(`FROM (VALUES`);
  w(filasImg.map((f, i) =>
    `    (${txt(f.url)}, ${txt(f.producto)}, ${txt(f.variante)}, ${f.orden})` +
    (i < filasImg.length - 1 ? ',' : '')).join('\n'));
  w(`) AS v(url, producto, variante, orden)`);
  w(`JOIN imagen_producto     im ON im.imagen_producto_url = v.url`);
  w(`JOIN productos           p  ON p.nombre = v.producto`);
  w(`JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante;`);
  w(``);
}


// ============================================================
// Las ofertas
// ============================================================
// La tienda oferta TODO. Cada uno de los otros cuatro toma un subconjunto.
const OFERTAS = [];

VARIANTES.forEach((v) => {
  const precioTienda = Math.round(v.precioBase * v.factor);

  // La tienda: siempre, y es la que se ensena en la pagina.
  //
  // Una de cada diez sale SIN unidades, a proposito. Si la tienda tuviera
  // stock en todo, el filtro de disponibilidad devolveria el catalogo entero
  // siempre y nadie sabria si funciona: no habria un solo producto agotado que
  // ensenar, ni el caso de "la tienda no tiene pero otro vendedor si", que es
  // el que hace falta para decidir que dice la tarjeta.
  OFERTAS.push({
    correo: TIENDA.correo, producto: v.producto, variante: v.nombre,
    precio: precioTienda,
    stock: azar() < 0.10 ? 0 : entre(3, 40),
    estado: 'activa', fecha: v.fecha,
  });

  // Los otros: cada uno entra con probabilidad, y a un precio cercano
  VENDEDORES.forEach((ven) => {
    if (azar() > 0.42) return;

    // Entre 8% mas barato y 8% mas caro que la tienda
    const factor = 0.92 + azar() * 0.16;
    const precio = Math.max(1, Math.round(precioTienda * factor));

    // Uno de cada diez entra pausado o sin unidades: sin eso, la pantalla
    // nunca ensena los casos que si van a pasar en produccion.
    const suerte = azar();
    const estado = suerte < 0.08 ? 'pausada' : 'activa';
    const stock = suerte >= 0.08 && suerte < 0.16 ? 0 : entre(1, 25);

    OFERTAS.push({
      correo: ven.correo, producto: v.producto, variante: v.nombre,
      precio, stock, estado, fecha: v.fecha,
    });
  });
});

w(`-- ============================================================`);
w(`-- Las ofertas: ${OFERTAS.length} sobre ${VARIANTES.length} variantes`);
w(`-- ============================================================`);
w(`-- Aqui vive el precio y el stock. Una fila por vendedor y variante, que es`);
w(`-- lo que garantiza el UNIQUE del 005.`);
w(`--`);
w(`-- Apunta al catalogo por los ids de MongoDB y sin llave foranea, igual que`);
w(`-- pedido_producto: una sola forma de identificar una variante en todo el`);
w(`-- sistema. Aqui se resuelven contra productos_variantes porque el conjunto`);
w(`-- de datos se escribe antes de que exista el documento, y son el mismo id.`);
w(`--`);
w(`-- La tienda tiene oferta de todas: por eso ningun producto se queda sin`);
w(`-- precio que ensenar. Los otros cuatro entran a veces si y a veces no, con`);
w(`-- una semilla fija, asi que hay variantes con un solo precio y otras con`);
w(`-- cinco. Alguna sale pausada o en cero a proposito: si todas estuvieran`);
w(`-- activas y con stock, la pantalla nunca ensenaria los casos que si van a`);
w(`-- pasar de verdad.`);
w(``);
// fecha_aprobacion (migracion 010) sale de la misma fecha de creacion, y no de
// una columna nueva en los VALUES de arriba, porque TODAS estas ofertas nacen
// aprobadas: son `activa` o `pausada`, y a esos dos estados no se llega sin que
// la tienda haya dado el visto bueno. Una oferta activa con la aprobacion en
// NULL es un estado que no puede existir, y sin esta linea las 552 quedarian
// justo asi -- la 010 no las arregla, porque el esquema corre antes que los
// datos y cuando ella pasa esta tabla todavia esta vacia.
//
// Ninguna nace `pendiente` a proposito. La semilla retrata un catalogo que ya
// funciona, y una oferta esperando revision para siempre no es eso. Para probar
// la cola de aprobacion basta publicar una desde el panel con cualquier cuenta
// ventas.*@mesh.com: el backend ya la crea pendiente sola.
// Y `id_usuario_aprobo` distingue los dos caminos de nacimiento que tiene una
// oferta, que es justo lo que esta columna existe para poder contar:
//
//   la tienda      nace aprobada sin que nadie la revise -> NULL, no consta quien
//   los demas      pasan por la cola y las aprueba la tienda -> su id
//
// NULL aqui NO significa "sin aprobar" -- la fecha ya dice que si -- significa
// que no hubo revisor. Por eso esta columna no puede llevar un CHECK que la
// empareje con la fecha: prohibiria el caso de la tienda, que son 202 de las 552.
w(`INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, stock, id_estado_oferta, fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)`);
w(`SELECT p.id_producto, pv.id_producto_variante, u.id_usuario, v.precio, v.stock, eo.id_estado_oferta, v.fecha::timestamptz, v.fecha::timestamptz, v.fecha::timestamptz,`);
w(`       CASE WHEN v.correo = ${txt(TIENDA.correo)} THEN NULL ELSE ut.id_usuario END`);
w(`FROM (VALUES`);
w(OFERTAS.map((o, i) =>
  `    (${txt(o.correo)}, ${txt(o.producto)}, ${txt(o.variante)}, ${num(o.precio)}.00, ${num(o.stock)}, ${txt(o.estado)}, ${txt(o.fecha)})` +
  (i < OFERTAS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(correo, producto, variante, precio, stock, estado, fecha)`);
w(`JOIN usuarios            u  ON u.correo_electronico = v.correo`);
w(`JOIN productos           p  ON p.nombre = v.producto`);
w(`JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante`);
w(`JOIN estado_oferta       eo ON eo.estado_oferta_nombre = v.estado`);
w(`JOIN usuarios            ut ON ut.correo_electronico = ${txt(TIENDA.correo)};`);
w(``);


// ============================================================
// El historial de precio
// ============================================================
// La fila de nacimiento de TODAS, y ademas dos cambios para algunas: sin un
// precio que haya cambiado no hay nada que reconstruir.
const CAMBIOS = [];
OFERTAS.forEach((o) => {
  // Nacimiento
  CAMBIOS.push({ ...o, precioFila: o.precio, fechaFila: o.fecha });
});

// A una de cada cuatro ofertas se le mueve el precio una o dos veces
const CON_CAMBIO = [];
OFERTAS.forEach((o) => {
  if (azar() > 0.25) return;
  const cuantos = entre(1, 2);
  let precio = o.precio;
  const mes0 = Number(o.fecha.slice(5, 7));
  for (let k = 1; k <= cuantos; k++) {
    const mes = Math.min(8, mes0 + k * 2);
    const dir = azar() < 0.5 ? -1 : 1;
    precio = Math.max(1, Math.round(precio * (1 + dir * (0.04 + azar() * 0.09))));
    const fecha = `2026-${String(mes).padStart(2, '0')}-${String(entre(1, 27)).padStart(2, '0')} 12:00:00-06`;
    CAMBIOS.push({ ...o, precioFila: precio, fechaFila: fecha });
    CON_CAMBIO.push({ correo: o.correo, producto: o.producto, variante: o.variante, precio, fecha });
  }
});

w(`-- ============================================================`);
w(`-- El historial de precio: ${CAMBIOS.length} filas`);
w(`-- ============================================================`);
w(`-- Una por el nacimiento de cada oferta, mas los cambios de una de cada`);
w(`-- cuatro. Es lo que hace reconstruible el precio a una fecha: sin ningun`);
w(`-- cambio, la funcion existiria pero no habria como ensenarla.`);
w(`--`);
w(`-- Se escriben a mano porque el trigger siempre pondria now(), y estas`);
w(`-- fechas son del pasado. Por eso esta apagado arriba.`);
w(``);
w(`INSERT INTO precio_historial (id_oferta, precio, id_usuario_modifico, fecha_creacion)`);
w(`SELECT o.id_oferta, v.precio, u.id_usuario, v.fecha::timestamptz`);
w(`FROM (VALUES`);
w(CAMBIOS.map((c, i) =>
  `    (${txt(c.correo)}, ${txt(c.producto)}, ${txt(c.variante)}, ${num(c.precioFila)}.00, ${txt(c.fechaFila)})` +
  (i < CAMBIOS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(correo, producto, variante, precio, fecha)`);
w(`JOIN usuarios            u  ON u.correo_electronico = v.correo`);
w(`JOIN productos           p  ON p.nombre = v.producto`);
w(`JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante`);
w(`JOIN oferta              o  ON o.id_producto_mongo = p.id_producto`);
w(`                            AND o.id_producto_variante_mongo = pv.id_producto_variante`);
w(`                            AND o.id_usuario = u.id_usuario;`);
w(``);
w(`-- La oferta se pone en su precio de HOY, que es el ultimo de su historial.`);
w(`-- Se deriva del historial en vez de escribirse otra vez: si se escribiera`);
w(`-- aparte, los dos podrian discrepar y nadie se enteraria.`);
w(`UPDATE oferta o`);
w(`SET precio = ultimo.precio`);
w(`FROM (`);
w(`    SELECT DISTINCT ON (id_oferta) id_oferta, precio`);
w(`    FROM precio_historial`);
w(`    ORDER BY id_oferta, fecha_creacion DESC, id_precio_historial DESC`);
w(`) AS ultimo`);
w(`WHERE ultimo.id_oferta = o.id_oferta;`);
w(``);


// ============================================================
// El kardex
// ============================================================
w(`-- ============================================================`);
w(`-- El kardex: la reposicion que explica el stock`);
w(`-- ============================================================`);
w(`-- Cada oferta nace con un movimiento de reposicion por sus unidades, para`);
w(`-- que el libro mayor nazca cuadrado. Si el saldo existiera sin un`);
w(`-- movimiento que lo explique, el kardex dejaria de servir para reconstruir`);
w(`-- la disponibilidad, que es lo unico para lo que existe.`);
w(``);
w(`INSERT INTO stock_movimiento (id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido, cantidad, stock_resultante, fecha_movimiento)`);
w(`SELECT o.id_oferta, m.id_motivo_movimiento, o.id_usuario, NULL, o.stock, o.stock, o.fecha_creacion`);
w(`FROM oferta o`);
w(`JOIN motivo_movimiento m ON m.motivo_nombre = 'reposicion'`);
w(`WHERE o.stock > 0;`);
w(``);


// ============================================================
// Pedidos
// ============================================================
w(`-- ============================================================`);
w(`-- Dos pedidos comprados`);
w(`-- ============================================================`);
w(`-- No se insertan a mano: se arman con las MISMAS funciones que usa la`);
w(`-- aplicacion. Asi el conjunto de datos no puede contradecir al flujo real,`);
w(`-- y de paso queda probado que las funciones corren.`);
w(``);
w(`DO $bloque$`);
w(`DECLARE`);
w(`    v_pedido  bigint;`);
w(`    v_dir     bigint;`);
w(`    v_usuario bigint;`);
w(`    v_of      record;`);
w(`BEGIN`);
w(`    -- Pedido de la compradora del norte: dos lineas de vendedores distintos,`);
w(`    -- que es lo que solo puede pasar en un modelo multi-vendedor.`);
w(`    SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir`);
w(`    FROM usuarios u`);
w(`    JOIN direcciones d        ON d.id_usuario = u.id_usuario`);
w(`    JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion`);
w(`    WHERE u.correo_electronico = 'compradora.norte@mesh.com'`);
w(`    LIMIT 1;`);
w(``);
w(`    v_pedido := crear_pedido(v_usuario, v_dir);`);
w(``);
w(`    FOR v_of IN`);
w(`        SELECT o.id_oferta, p.id_producto, pv.id_producto_variante, p.nombre AS np, pv.nombre_variante AS nv`);
w(`        FROM oferta o`);
w(`        JOIN productos_variantes pv ON pv.id_producto = o.id_producto_mongo`);
w(`                                     AND pv.id_producto_variante = o.id_producto_variante_mongo`);
w(`        JOIN productos p            ON p.id_producto = pv.id_producto`);
w(`        JOIN estado_oferta eo       ON eo.id_estado_oferta = o.id_estado_oferta`);
w(`        WHERE eo.estado_oferta_nombre = 'activa' AND o.stock >= 2`);
w(`        ORDER BY o.id_oferta`);
w(`        LIMIT 2`);
w(`    LOOP`);
w(`        PERFORM agregar_linea(v_pedido, jsonb_build_object(`);
w(`            'id_oferta', v_of.id_oferta, 'cantidad', 1,`);
w(`            'id_producto', v_of.id_producto, 'id_producto_variante', v_of.id_producto_variante,`);
w(`            'nombre_producto', v_of.np, 'nombre_variante', v_of.nv));`);
w(`    END LOOP;`);
w(``);
w(`    PERFORM comprar_pedido(v_pedido, 'tarjeta');`);
w(``);
w(`    -- Pedido del comprador del sur: una linea, contra entrega`);
w(`    SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir`);
w(`    FROM usuarios u`);
w(`    JOIN direcciones d        ON d.id_usuario = u.id_usuario`);
w(`    JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion`);
w(`    WHERE u.correo_electronico = 'comprador.sur@mesh.com'`);
w(`    LIMIT 1;`);
w(``);
w(`    v_pedido := crear_pedido(v_usuario, v_dir);`);
w(``);
w(`    SELECT o.id_oferta, p.id_producto, pv.id_producto_variante, p.nombre AS np, pv.nombre_variante AS nv`);
w(`    INTO v_of`);
w(`    FROM oferta o`);
w(`    JOIN productos_variantes pv ON pv.id_producto = o.id_producto_mongo`);
w(`                                 AND pv.id_producto_variante = o.id_producto_variante_mongo`);
w(`    JOIN productos p            ON p.id_producto = pv.id_producto`);
w(`    JOIN estado_oferta eo       ON eo.id_estado_oferta = o.id_estado_oferta`);
w(`    WHERE eo.estado_oferta_nombre = 'activa' AND o.stock >= 3`);
w(`    ORDER BY o.id_oferta DESC`);
w(`    LIMIT 1;`);
w(``);
w(`    PERFORM agregar_linea(v_pedido, jsonb_build_object(`);
w(`        'id_oferta', v_of.id_oferta, 'cantidad', 2,`);
w(`        'id_producto', v_of.id_producto, 'id_producto_variante', v_of.id_producto_variante,`);
w(`        'nombre_producto', v_of.np, 'nombre_variante', v_of.nv));`);
w(``);
w(`    PERFORM comprar_pedido(v_pedido, 'efectivo contra entrega');`);
w(`END`);
w(`$bloque$;`);
w(``);


// ============================================================
// Cierre: encender el trigger y comprobarse a si mismo
// ============================================================
w(`-- ============================================================`);
w(`-- El trigger vuelve, y el conjunto se comprueba a si mismo`);
w(`-- ============================================================`);
w(`-- Un conjunto de datos que no se verifica es un conjunto de datos que`);
w(`-- miente en silencio. Estas siete comprobaciones fallan la migracion entera`);
w(`-- si algo no cuadra, en vez de dejar la base torcida y que alguien lo`);
w(`-- descubra tres semanas despues.`);
w(``);
w(`ALTER TABLE oferta ENABLE TRIGGER trg_oferta_registrar_precio;`);
w(``);
w(`DO $verificar$`);
w(`DECLARE`);
w(`    v_mal  integer;`);
w(`BEGIN`);
w(`    -- 1. El saldo de cada oferta es la suma de su kardex`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM oferta o`);
w(`    LEFT JOIN (`);
w(`        SELECT sm.id_oferta, sum(sm.cantidad * mm.valor) AS saldo`);
w(`        FROM stock_movimiento sm`);
w(`        JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento`);
w(`        GROUP BY sm.id_oferta`);
w(`    ) k ON k.id_oferta = o.id_oferta`);
w(`    WHERE o.stock <> coalesce(k.saldo, 0);`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% ofertas tienen un stock que su kardex no explica', v_mal;`);
w(`    END IF;`);
w(``);
w(`    -- 2. El precio de cada oferta es el ultimo de su historial`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM oferta o`);
w(`    JOIN LATERAL (`);
w(`        SELECT precio FROM precio_historial ph`);
w(`        WHERE ph.id_oferta = o.id_oferta`);
w(`        ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC LIMIT 1`);
w(`    ) ultimo ON true`);
w(`    WHERE o.precio <> ultimo.precio;`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% ofertas tienen un precio distinto al ultimo de su historial', v_mal;`);
w(`    END IF;`);
w(``);
w(`    -- 3. Toda variante tiene la oferta de la tienda: es lo que garantiza que`);
w(`    --    ningun producto se quede sin precio que ensenar en la pagina`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM productos_variantes pv`);
w(`    WHERE NOT EXISTS (`);
w(`        SELECT 1 FROM oferta o`);
w(`        JOIN usuarios u ON u.id_usuario = o.id_usuario`);
w(`        WHERE o.id_producto_mongo = pv.id_producto`);
w(`          AND o.id_producto_variante_mongo = pv.id_producto_variante`);
w(`          AND u.correo_electronico = 'tienda@mesh.com'`);
w(`    );`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% variantes no tienen oferta de la tienda', v_mal;`);
w(`    END IF;`);
w(``);
w(`    -- 4. Ninguna oferta que circula esta sin aprobar. A 'activa' y a`);
w(`    --    'pausada' no se llega sin el visto bueno de la tienda, asi que una`);
w(`    --    de esas con fecha_aprobacion en NULL es un estado imposible.`);
w(`    --    Esta comprobacion existe porque la base NO lo puede impedir sola:`);
w(`    --    un CHECK no admite subconsultas y meter el id del estado a mano`);
w(`    --    dentro de la restriccion esta prohibido (migrations/README.md).`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM oferta o`);
w(`    JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta`);
w(`    WHERE eo.estado_oferta_nombre IN ('activa', 'pausada')`);
w(`      AND o.fecha_aprobacion IS NULL;`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% ofertas circulan sin fecha de aprobacion', v_mal;`);
w(`    END IF;`);
w(``);
w(`    -- 5. Y la reciproca: una oferta 'pendiente' o 'rechazada' NO puede tener`);
w(`    --    fecha de aprobacion. A 'rechazada' solo se llega desde 'pendiente'`);
w(`    --    (el backend rechaza revisar cualquier otro estado), y el rechazo no`);
w(`    --    toca la fecha, asi que las dos comparten la misma invariante.`);
w(`    --`);
w(`    --    Esta mitad importa mas de lo que parece: la fecha de aprobacion es`);
w(`    --    el candado que impide que un vendedor active su propia oferta, asi`);
w(`    --    que una fila sin aprobar pero CON fecha es una que se puede publicar`);
w(`    --    sola, saltandose la revision.`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM oferta o`);
w(`    JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta`);
w(`    WHERE eo.estado_oferta_nombre IN ('pendiente', 'rechazada')`);
w(`      AND o.fecha_aprobacion IS NOT NULL;`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% ofertas sin aprobar ya traen fecha de aprobacion', v_mal;`);
w(`    END IF;`);
w(``);
w(`    -- 6. Nadie aprobo una oferta que no esta aprobada. Al reves SI se puede`);
w(`    --    (la tienda nace aprobada y sin revisor), asi que solo se comprueba`);
w(`    --    esta mitad: si hay aprobador, tiene que haber fecha.`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM oferta`);
w(`    WHERE id_usuario_aprobo IS NOT NULL`);
w(`      AND fecha_aprobacion IS NULL;`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% ofertas tienen aprobador pero no fecha de aprobacion', v_mal;`);
w(`    END IF;`);
w(``);
w(`    -- 7. Toda direccion tiene calle, en la fila viva y en su historial. Sin`);
w(`    --    ella no se entrega un pedido, y el backend la exige al crear una`);
w(`    --    nueva: los datos de prueba no pueden ser los unicos que se saltan`);
w(`    --    la regla.`);
w(`    --    Se cuentan DIRECCIONES distintas, no filas: una direccion sin calle`);
w(`    --    arrastra tambien su fila de historial, y sumar las dos tablas`);
w(`    --    reportaria el doble. Quien lea "2" saldria a buscar dos direcciones`);
w(`    --    rotas cuando solo hay una.`);
w(`    SELECT count(*) INTO v_mal`);
w(`    FROM direcciones d`);
w(`    WHERE d.direccion_exacta IS NULL`);
w(`       OR EXISTS (SELECT 1 FROM direccion_historial h`);
w(`                   WHERE h.id_direccion = d.id_direccion`);
w(`                     AND h.direccion_exacta IS NULL);`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% direcciones se quedaron sin calle', v_mal;`);
w(`    END IF;`);
w(``);
w(`    RAISE NOTICE 'Conjunto de datos verificado: kardex, precios, ofertas de la tienda, aprobaciones y direcciones cuadran';`);
w(`END`);
w(`$verificar$;`);
w(``);
w(`COMMIT;`);
w(``);


// ============================================================
// Escribir
// ============================================================
// Antes de escribir: ninguna fecha puede caer fuera del calendario.
//
// Esta comprobacion existe porque paso. Al triplicar el catalogo, el reparto
// de fechas se salio de diciembre y genero '2026-19-05'. El archivo se
// escribio igual, sin una queja, y el fallo aparecio mucho despues -- al
// cargarlo -- como un error de psql que tumbaba la migracion entera. Fallar
// aqui cuesta un segundo; descubrirlo alla cuesta una tarde.
//
// El dia se limita a 28 y no a 31 a proposito: el reparto usa meses de 28
// dias, asi que un 30 seria senal de que la cuenta se desalineo, aunque sea
// una fecha que exista.
const sql = L.join('\n');
const fechasMalas = [];
for (const m of sql.matchAll(/'(\d{4})-(\d{2})-(\d{2}) \d{2}:\d{2}:\d{2}[-+]\d{2}'/g)) {
  const mes = Number(m[2]);
  const dia = Number(m[3]);
  if (mes < 1 || mes > 12 || dia < 1 || dia > 28) fechasMalas.push(m[0]);
}
if (fechasMalas.length > 0) {
  console.error(`\nNO se escribio nada: ${fechasMalas.length} fechas fuera del calendario.`);
  console.error('   ' + [...new Set(fechasMalas)].slice(0, 5).join(', '));
  console.error('Revisa el reparto de fechas de PRODUCTOS: MES_TOPE y paso.');
  process.exit(1);
}

const salida = path.join(__dirname, '001_catalogo.sql');
fs.writeFileSync(salida, sql, 'utf8');

console.log(`Escrito ${path.relative(process.cwd(), salida)}`);
console.log(`  categorias   ${CATALOGO.length} raices, ${filasHojas.length} hojas`);
console.log(`  productos    ${PRODUCTOS.length}`);
console.log(`  variantes    ${VARIANTES.length}`);
console.log(`  caracteristicas  ${CARACTERISTICAS.length} de producto, ${CARACTERISTICAS_VARIANTE.length} de variante`);
console.log(`  valores      ${filasCar.length} de producto, ${filasCarVar.length} de variante`);
console.log(`  historial    ${FILAS_HIST.length} filas de producto, ${FILAS_HIST_VAR.length} de variante`);
console.log(`  ofertas      ${OFERTAS.length}`);
console.log(`  precios      ${CAMBIOS.length} filas de historial`);
console.log(`  usuarios     ${USUARIOS.length}`);
