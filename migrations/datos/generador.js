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
        car: { Marca:'Aurora', Modelo:'A14-2026', 'Pais de origen':'China', Garantia:24, Peso:1.28,
               'Duracion de la bateria':11.5, 'Contenido del paquete':['Laptop','Cargador USB-C','Guia rapida'] },
        variantes: [
          { nombre:'16 GB / 512 GB', factor:1.00, car:{ 'Memoria RAM':16, Almacenamiento:512, 'Tamano de pantalla':14.0, Color:'Gris grafito' } },
          { nombre:'32 GB / 1 TB',   factor:1.42, car:{ 'Memoria RAM':32, Almacenamiento:1024,'Tamano de pantalla':14.0, Color:'Gris grafito', Acabado:'Mate' } },
        ] },
      { nombre: 'Laptop Bastion 16', precio: 9400,
        descripcion: 'Estacion de trabajo de 16 pulgadas para render y compilacion.',
        car: { Marca:'Bastion', Modelo:'W16-Pro', Garantia:36, Peso:2.15, 'Duracion de la bateria':7.0,
               Certificaciones:['MIL-STD-810H','Energy Star'], 'Material principal':'Aleacion de magnesio' },
        variantes: [
          { nombre:'32 GB / 1 TB', factor:1.00, car:{ 'Memoria RAM':32, Almacenamiento:1024, 'Tamano de pantalla':16.0, Color:'Negro' } },
          { nombre:'64 GB / 2 TB', factor:1.55, car:{ 'Memoria RAM':64, Almacenamiento:2048, 'Tamano de pantalla':16.0, Color:'Negro' } },
        ] },
      { nombre: 'Laptop Nimbo 13', precio: 4100,
        descripcion: 'Equipo de entrada para estudio y oficina, silencioso y sin ventilador.',
        car: { Marca:'Nimbo', Modelo:'N13', 'Pais de origen':'Vietnam', Garantia:12, Peso:1.05 },
        variantes: [
          { nombre:'8 GB / 256 GB', factor:1.00, car:{ 'Memoria RAM':8, Almacenamiento:256, 'Tamano de pantalla':13.3, Color:'Plata' } },
        ] },
    ] },

  { nombre: 'Telefonos',
    paleta: ['Marca','Modelo','Pais de origen','Garantia','Peso','Impermeable','Contenido del paquete','Duracion de la bateria','Certificaciones'],
    paletaVariante: ['Almacenamiento','Color','Tamano de pantalla','Memoria RAM'],
    productos: [
      { nombre: 'Telefono Vela 7', precio: 5300,
        descripcion: 'Pantalla OLED de 6.4 pulgadas y camara principal de 50 MP.',
        car: { Marca:'Vela', Modelo:'V7', Garantia:12, Peso:0.19, Impermeable:true,
               'Contenido del paquete':['Telefono','Cable USB-C','Pin de bandeja'] },
        variantes: [
          { nombre:'128 GB', factor:1.00, car:{ Almacenamiento:128, Color:'Azul medianoche', 'Tamano de pantalla':6.4 } },
          { nombre:'256 GB', factor:1.18, car:{ Almacenamiento:256, Color:'Azul medianoche', 'Tamano de pantalla':6.4 } },
          { nombre:'512 GB', factor:1.36, car:{ Almacenamiento:512, Color:'Grafito', 'Tamano de pantalla':6.4 } },
        ] },
      { nombre: 'Telefono Ceibo Lite', precio: 1850,
        descripcion: 'Bateria de dos dias y ranura para memoria expandible.',
        car: { Marca:'Ceibo', Modelo:'Lite-3', 'Pais de origen':'India', Garantia:12, 'Duracion de la bateria':48.0 },
        variantes: [
          { nombre:'64 GB',  factor:1.00, car:{ Almacenamiento:64,  Color:'Verde', 'Tamano de pantalla':6.1 } },
          { nombre:'128 GB', factor:1.22, car:{ Almacenamiento:128, Color:'Negro', 'Tamano de pantalla':6.1 } },
        ] },
    ] },

  { nombre: 'Audifonos',
    paleta: ['Marca','Modelo','Garantia','Inalambrico','Impermeable','Duracion de la bateria','Peso','Contenido del paquete'],
    paletaVariante: ['Color','Acabado','Longitud del cable'],
    productos: [
      { nombre: 'Audifonos Sereno ANC', precio: 1450,
        descripcion: 'Diadema cerrada con cancelacion activa y estuche rigido.',
        car: { Marca:'Sereno', Modelo:'ANC-2', Garantia:24, Inalambrico:true, 'Duracion de la bateria':38.0, Peso:0.26,
               'Contenido del paquete':['Audifonos','Estuche rigido','Cable de 3.5 mm','Cable USB-C'] },
        variantes: [
          { nombre:'Negro', factor:1.00, car:{ Color:'Negro', Acabado:'Mate' } },
          { nombre:'Arena', factor:1.00, car:{ Color:'Arena', Acabado:'Mate' } },
        ] },
      { nombre: 'Audifonos Brisa Sport', precio: 620,
        descripcion: 'Intraurales con gancho de silicona, pensados para correr.',
        car: { Marca:'Brisa', Garantia:12, Inalambrico:true, Impermeable:true, 'Duracion de la bateria':9.0 },
        variantes: [
          { nombre:'Verde lima', factor:1.00, car:{ Color:'Verde lima' } },
          { nombre:'Gris',       factor:1.00, car:{ Color:'Gris' } },
        ] },
      { nombre: 'Audifonos Estudio 900', precio: 2100,
        descripcion: 'Monitoreo de referencia con cable desmontable de 3 metros.',
        car: { Marca:'Estudio', Modelo:'900', Garantia:24, Inalambrico:false, Peso:0.31 },
        variantes: [
          { nombre:'Cable 3 m', factor:1.00, car:{ Color:'Negro', 'Longitud del cable':3.0 } },
        ] },
    ] },

  { nombre: 'Monitores',
    paleta: ['Marca','Modelo','Garantia','Peso','Certificaciones','Contenido del paquete','Material principal'],
    paletaVariante: ['Tamano de pantalla','Tasa de refresco','Color','Acabado'],
    productos: [
      { nombre: 'Monitor Horizonte 27', precio: 2750,
        descripcion: 'Panel IPS de 27 pulgadas con base ajustable en altura.',
        car: { Marca:'Horizonte', Modelo:'H27', Garantia:36, Peso:5.4,
               Certificaciones:['TUV Eye Comfort','Energy Star'] },
        variantes: [
          { nombre:'75 Hz',  factor:1.00, car:{ 'Tamano de pantalla':27.0, 'Tasa de refresco':75,  Color:'Negro' } },
          { nombre:'165 Hz', factor:1.33, car:{ 'Tamano de pantalla':27.0, 'Tasa de refresco':165, Color:'Negro', Acabado:'Antirreflejo' } },
        ] },
      { nombre: 'Monitor Panorama 34', precio: 5900,
        descripcion: 'Ultrapanoramico curvo de 34 pulgadas, ideal para dos ventanas lado a lado.',
        car: { Marca:'Panorama', Modelo:'UW34', Garantia:24, Peso:7.9, 'Material principal':'Plastico ABS' },
        variantes: [
          { nombre:'100 Hz', factor:1.00, car:{ 'Tamano de pantalla':34.0, 'Tasa de refresco':100, Color:'Grafito' } },
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
        car: { Marca:'Alba', 'Material principal':'Acero inoxidable', Potencia:1350, Garantia:24,
               'Contenido del paquete':['Cafetera','Portafiltro doble','Cuchara medidora'] },
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
          { nombre:'2 L',   factor:1.15, car:{ Capacidad:2.0, Color:'Negro' } },
        ] },
    ] },

  { nombre: 'Muebles',
    paleta: ['Marca','Modelo','Material principal','Peso','Requiere ensamblaje','Garantia','Contenido del paquete','Pais de origen','Certificaciones'],
    paletaVariante: ['Color','Acabado','Talla'],
    productos: [
      { nombre: 'Escritorio Roble 120', precio: 2350,
        descripcion: 'Tablero de 120 por 60 cm con pasacables y estructura de acero.',
        car: { Marca:'Roble', 'Material principal':'Madera de pino', 'Requiere ensamblaje':true, Peso:18.5, Garantia:24,
               'Contenido del paquete':['Tablero','Patas','Tornilleria','Llave allen'] },
        variantes: [
          { nombre:'Natural', factor:1.00, car:{ Color:'Natural', Acabado:'Barnizado' } },
          { nombre:'Nogal',   factor:1.00, car:{ Color:'Nogal',   Acabado:'Barnizado' } },
        ] },
      { nombre: 'Silla ergonomica Vertebra', precio: 3100,
        descripcion: 'Respaldo de malla, soporte lumbar regulable y apoyabrazos 3D.',
        car: { Marca:'Vertebra', 'Material principal':'Malla y nylon', 'Requiere ensamblaje':true, Garantia:60, Peso:14.0 },
        variantes: [
          { nombre:'Negra', factor:1.00, car:{ Color:'Negro' } },
          { nombre:'Gris',  factor:1.00, car:{ Color:'Gris' } },
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
          { nombre:'Negra',  factor:1.00, car:{ Color:'Negro',  'Longitud del cable':1.8 } },
        ] },
      { nombre: 'Tira LED Aurora 5 m', precio: 320,
        descripcion: 'Cinco metros regulables con control remoto y adhesivo 3M.',
        car: { Marca:'Aurora', Potencia:24, Inalambrico:true, Garantia:12, Certificaciones:['CE','RoHS'] },
        variantes: [
          { nombre:'Multicolor', factor:1.00, car:{ Color:'Multicolor', 'Longitud del cable':5.0 } },
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
          { nombre:'S azul',  factor:1.00, car:{ Talla:'S', Color:'Azul' } },
          { nombre:'M azul',  factor:1.00, car:{ Talla:'M', Color:'Azul' } },
          { nombre:'L blanca',factor:1.00, car:{ Talla:'L', Color:'Blanco' } },
        ] },
      { nombre: 'Camisa oxford clasica', precio: 290,
        descripcion: 'Oxford de algodon peinado, cuello con botones.',
        car: { Marca:'Telar', 'Material principal':'Algodon', 'Origen del algodon':'Peru',
               Certificaciones:['OEKO-TEX Standard 100'] },
        variantes: [
          { nombre:'M celeste', factor:1.00, car:{ Talla:'M', Color:'Celeste', Acabado:'Lavado suave' } },
          { nombre:'L celeste', factor:1.00, car:{ Talla:'L', Color:'Celeste' } },
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
          { nombre:'34 azul',  factor:1.00, car:{ Talla:'34', Color:'Azul marino' } },
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
          { nombre:'40 cafe',  factor:1.00, car:{ 'Numero de calzado':40, Color:'Cafe' } },
          { nombre:'42 cafe',  factor:1.00, car:{ 'Numero de calzado':42, Color:'Cafe' } },
          { nombre:'42 negro', factor:1.00, car:{ 'Numero de calzado':42, Color:'Negro', Acabado:'Pulido' } },
        ] },
      { nombre: 'Bota impermeable Cumbre', precio: 1150,
        descripcion: 'Membrana impermeable y suela con agarre para roca mojada.',
        car: { Marca:'Cumbre', 'Material principal':'Nobuck', Impermeable:true, Garantia:12, Peso:1.15 },
        variantes: [
          { nombre:'41', factor:1.00, car:{ 'Numero de calzado':41, Color:'Marron' } },
          { nombre:'43', factor:1.00, car:{ 'Numero de calzado':43, Color:'Marron' } },
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
          { nombre:'Naranja',factor:1.00, car:{ Talla:'5', Color:'Naranja' } },
        ] },
      { nombre: 'Espinilleras Muralla', precio: 145,
        descripcion: 'Placa rigida con espuma de alta densidad y mallas sujetadoras.',
        car: { Marca:'Muralla', 'Material principal':'Polipropileno', Peso:0.16 },
        variantes: [
          { nombre:'M', factor:1.00, car:{ Talla:'M', Color:'Negro' } },
          { nombre:'L', factor:1.00, car:{ Talla:'L', Color:'Negro' } },
        ] },
    ] },

  { nombre: 'Ciclismo',
    paleta: ['Marca','Modelo','Material principal','Garantia','Peso','Certificaciones','Contenido del paquete','Pais de origen'],
    paletaVariante: ['Talla','Color','Acabado'],
    productos: [
      { nombre: 'Casco de ruta Aerodino', precio: 690,
        descripcion: 'Veintidos ventilaciones y ajuste micrometrico en la nuca.',
        car: { Marca:'Aerodino', 'Material principal':'Policarbonato y EPS', Certificaciones:['CPSC','EN 1078'],
               Peso:0.27, Garantia:24 },
        variantes: [
          { nombre:'M blanco', factor:1.00, car:{ Talla:'M', Color:'Blanco' } },
          { nombre:'L negro',  factor:1.00, car:{ Talla:'L', Color:'Negro', Acabado:'Mate' } },
        ] },
      { nombre: 'Bomba de piso Piston', precio: 310,
        descripcion: 'Manometro analogico hasta 160 psi y cabezal para las dos valvulas.',
        car: { Marca:'Piston', 'Material principal':'Acero', Garantia:24,
               'Contenido del paquete':['Bomba','Adaptador de balon','Aguja'] },
        variantes: [
          { nombre:'Estandar', factor:1.00, car:{ Color:'Negro' } },
        ] },
    ] },

  { nombre: 'Fitness',
    paleta: ['Marca','Modelo','Material principal','Nivel de resistencia','Peso','Contenido del paquete','Certificaciones','Pais de origen'],
    paletaVariante: ['Color','Talla'],
    productos: [
      { nombre: 'Set de bandas elasticas', precio: 195,
        descripcion: 'Cinco bandas de latex con distinta resistencia y bolsa de malla.',
        car: { Marca:'Tension', 'Material principal':'Latex natural', 'Nivel de resistencia':'Progresiva 5 a 25 kg',
               'Contenido del paquete':['5 bandas','Bolsa de malla','Guia de ejercicios'] },
        variantes: [
          { nombre:'Set completo', factor:1.00, car:{ Color:'Multicolor' } },
        ] },
      { nombre: 'Tapete de yoga Raiz 6 mm', precio: 380,
        descripcion: 'Seis milimetros de TPE con superficie antideslizante en las dos caras.',
        car: { Marca:'Raiz', 'Material principal':'TPE', Peso:1.1 },
        variantes: [
          { nombre:'Verde', factor:1.00, car:{ Color:'Verde' } },
          { nombre:'Morado',factor:1.00, car:{ Color:'Morado' } },
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
          { nombre:'Pasta dura',   factor:1.55, car:{ Formato:'Pasta dura' } },
        ] },
      { nombre: 'Cuentos de la ceiba', precio: 145,
        descripcion: 'Doce relatos breves sobre la memoria y el desarraigo.',
        car: { Autor:'Tomas Arriaga', Editorial:'Cadejo', Paginas:186, Idioma:'Espanol', 'Anio de publicacion':2022 },
        variantes: [
          { nombre:'Pasta blanda', factor:1.00, car:{ Formato:'Pasta blanda' } },
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
          { nombre:'Digital',    factor:0.55, car:{ Formato:'PDF con DRM' } },
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
        car: { Marca:'Clara', 'Tipo de piel':'Mixta a grasa',
               'Ingredientes destacados':['Niacinamida','Zinc PCA'], 'Pais de origen':'Corea del Sur' },
        variantes: [
          { nombre:'30 ml', factor:1.00, car:{ Volumen:30 } },
          { nombre:'50 ml', factor:1.48, car:{ Volumen:50 } },
        ] },
      { nombre: 'Protector solar mineral FPS 50', precio: 265,
        descripcion: 'Filtro mineral sin fragancia, apto para piel sensible.',
        car: { Marca:'Clara', 'Tipo de piel':'Sensible',
               'Ingredientes destacados':['Oxido de zinc','Vitamina E'], Certificaciones:['Dermatologicamente probado'] },
        variantes: [
          { nombre:'50 ml', factor:1.00, car:{ Volumen:50 } },
        ] },
    ] },

  { nombre: 'Fragancias',
    paleta: ['Marca','Tipo de fragancia','Pais de origen','Ingredientes destacados','Certificaciones','Contenido del paquete','Peso','Garantia'],
    paletaVariante: ['Volumen','Color'],
    productos: [
      { nombre: 'Eau de parfum Bruma', precio: 720,
        descripcion: 'Salida citrica, fondo amaderado, doce horas de fijacion.',
        car: { Marca:'Bruma', 'Tipo de fragancia':'Amaderada citrica', 'Pais de origen':'Francia',
               'Ingredientes destacados':['Bergamota','Cedro','Vetiver'] },
        variantes: [
          { nombre:'50 ml',  factor:1.00, car:{ Volumen:50 } },
          { nombre:'100 ml', factor:1.62, car:{ Volumen:100 } },
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
// Wikimedia solo genera miniaturas con anchos de una lista fija: 960 si, 800
// no. Y corta por ritmo con 429, que se lee igual que un enlace muerto.
const IMAGENES = {
  'Laptop Aurora 14':        ['https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Laptop-hard-drive-exposed.jpg/960px-Laptop-hard-drive-exposed.jpg'],
  'Telefono Vela 7':         ['https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/Smartphone_icon.png/960px-Smartphone_icon.png'],
  'Audifonos Sereno ANC':    ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/8e/Sennheiser_HD_650.jpg/960px-Sennheiser_HD_650.jpg'],
  'Camisa de lino manga larga': ['https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Blue_Business_Shirt.jpg/960px-Blue_Business_Shirt.jpg'],
  'Cafetera Alba Espresso':  ['https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Espresso_machine_at_work.jpg/960px-Espresso_machine_at_work.jpg'],
  'Balon de futbol numero 5':['https://upload.wikimedia.org/wikipedia/commons/thumb/d/d3/Soccerball.svg/960px-Soccerball.svg.png'],
  'El camino de las nubes':  ['https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Open_book_nae_02.svg/960px-Open_book_nae_02.svg.png'],
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
w(`INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, codigo_postal, id_estado_direccion)`);
w(`SELECT u.id_usuario, v.pais, v.departamento, v.ciudad, v.codigo, ed.id_estado_direccion`);
w(`FROM (VALUES`);
w(`    ('compradora.norte@mesh.com', 'Guatemala', 'Guatemala',     'Guatemala', '01010'),`);
w(`    ('comprador.sur@mesh.com',    'Guatemala', 'Sacatepequez',  'Antigua Guatemala', '03001')`);
w(`) AS v(correo, pais, departamento, ciudad, codigo)`);
w(`JOIN usuarios u ON u.correo_electronico = v.correo`);
w(`JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa'`);
w(`WHERE NOT EXISTS (SELECT 1 FROM direcciones d WHERE d.id_usuario = u.id_usuario);`);
w(``);
w(`-- Su primera version en el historial. El pedido apunta AQUI y no a`);
w(`-- direcciones: guarda a donde se mando de verdad, aunque despues la editen.`);
w(`INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, codigo_postal)`);
w(`SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.codigo_postal`);
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

// Un dia distinto por producto, empezando en enero y avanzando de a poco
PRODUCTOS.forEach((p, i) => {
  const dia = 3 + i * 5;
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
w(`INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, stock, id_estado_oferta, fecha_creacion, fecha_actualizacion)`);
w(`SELECT p.id_producto, pv.id_producto_variante, u.id_usuario, v.precio, v.stock, eo.id_estado_oferta, v.fecha::timestamptz, v.fecha::timestamptz`);
w(`FROM (VALUES`);
w(OFERTAS.map((o, i) =>
  `    (${txt(o.correo)}, ${txt(o.producto)}, ${txt(o.variante)}, ${num(o.precio)}.00, ${num(o.stock)}, ${txt(o.estado)}, ${txt(o.fecha)})` +
  (i < OFERTAS.length - 1 ? ',' : '')).join('\n'));
w(`) AS v(correo, producto, variante, precio, stock, estado, fecha)`);
w(`JOIN usuarios            u  ON u.correo_electronico = v.correo`);
w(`JOIN productos           p  ON p.nombre = v.producto`);
w(`JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante`);
w(`JOIN estado_oferta       eo ON eo.estado_oferta_nombre = v.estado;`);
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
w(`JOIN oferta              o  ON o.id_producto_variante_mongo = pv.id_producto_variante AND o.id_usuario = u.id_usuario;`);
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
w(`        JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante_mongo`);
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
w(`    JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante_mongo`);
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
w(`-- miente en silencio. Estas tres comprobaciones fallan la migracion entera`);
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
w(`        WHERE o.id_producto_variante_mongo = pv.id_producto_variante`);
w(`          AND u.correo_electronico = 'tienda@mesh.com'`);
w(`    );`);
w(``);
w(`    IF v_mal > 0 THEN`);
w(`        RAISE EXCEPTION '% variantes no tienen oferta de la tienda', v_mal;`);
w(`    END IF;`);
w(``);
w(`    RAISE NOTICE 'Conjunto de datos verificado: kardex, precios y ofertas de la tienda cuadran';`);
w(`END`);
w(`$verificar$;`);
w(``);
w(`COMMIT;`);
w(``);


// ============================================================
// Escribir
// ============================================================
const salida = path.join(__dirname, '001_catalogo.sql');
fs.writeFileSync(salida, L.join('\n'), 'utf8');

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
