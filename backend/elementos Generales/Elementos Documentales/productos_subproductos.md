# Características de Producto

Este documento tiene dos partes.

**Arriba, lo obligatorio.** Son los campos que todo documento de producto lleva
siempre, sin importar la categoría. No son una propuesta: ya existen en el modelo
relacional y son los que el ETL escribe hoy en MongoDB. Si un documento no los
trae, está incompleto.

**Abajo, lo opcional.** Las características que cada categoría puede traer o no.
Los atributos de una laptop no se parecen a los de una camisa, y esa es
precisamente la razón por la que el catálogo se migró a una base documental.

---

## Obligatorias

Lo que lleva todo producto, siempre.

### Raíz del documento

| Campo | Tipo | Ejemplo | De dónde sale |
| --- | --- | --- | --- |
| `_id` | `Number` | `1` | Es el `id_producto` de PostgreSQL, no uno que genere Mongo |
| `nombre` | `String` | `"Camisa de lino manga larga"` | `productos.nombre` |
| `descripcion` | `String` | `"Camisa de lino de corte regular"` | `productos.descripcion` |
| `fecha_creacion` | `Date` | `2026-01-10T15:00:00Z` | `productos.fecha_creacion` |
| `estado` | `String` | `"activo"` | Catálogo `estado_producto` |
| `vendedor` | `Object` | ver abajo | `usuarios`, por `productos.id_usuario` |
| `categoria` | `Object` | ver abajo | `categorias`, por `productos.id_categoria` |
| `variantes` | `Array<Object>` | ver abajo | `productos_variantes` |

### vendedor

| Campo | Tipo | Ejemplo |
| --- | --- | --- |
| `id_usuario` | `Number` | `5` |
| `usuario` | `String` | `"vendedor_prueba"` |
| `nombre` | `String` | `"Carlos"` |
| `apellido` | `String` | `"Ramirez"` |

### categoria

| Campo | Tipo | Ejemplo |
| --- | --- | --- |
| `id_categoria` | `Number` | `7` |
| `nombre` | `String` | `"Cocina"` |
| `categoria_padre` | `String` | `"Hogar"` |
| `porcentaje_comision` | `Decimal128` | `7.50` |

### Cada elemento de variantes

| Campo | Tipo | Ejemplo |
| --- | --- | --- |
| `id_producto_variante` | `Number` | `1` |
| `nombre_variante` | `String` | `"M azul"` |
| `precio` | `Decimal128` | `169.00` |
| `descripcion` | `String` | `"Talla M, color azul"` |
| `fecha_creacion` | `Date` | `2026-01-10T15:00:00Z` |
| `estado` | `String` | `"activa"` |
| `imagenes` | `Array<String>` | `["https://.../camisa.jpg"]` |

**Sobre el dinero.** `precio` y `porcentaje_comision` van en `Decimal128`, no en
`Number`. Con punto flotante los centavos se redondean mal y el error se acumula.

**Sobre `descripcion`.** Es el único campo obligatorio de la lista que en
PostgreSQL acepta nulo. Hoy los tres productos de prueba lo traen.

Un ejemplo completo de cómo queda el documento está en
[ejemplos_bson_productos.md](ejemplos_bson_productos.md).

---

## Opcionales

Según la categoría. Un producto puede traer todas, algunas o ninguna.

## Tabla 1 — Características generales

| Característica | Tipo de dato | Estructura aproximada |
| --- | --- | --- |
| **Marca** | `String` | `"Lenovo"` |
| **Modelo** | `String` | `"IdeaPad 5 15IAL7"` |
| **Categoría** | `Object / String` | `{ id: "cat_001", nombre: "Electrónicos" }` |
| **Subcategoría** | `Object / String` | `{ id: "sub_001", nombre: "Laptops" }` |
| **Fabricante** | `String` | `"Lenovo Group Limited"` |
| **País de origen** | `String` | `"China"` |
| **Garantía** | `Boolean / Object` | `{ disponible: true, tipo: "Fabricante" }` |
| **Duración de la garantía** | `Number / Object` | `{ valor: 12, unidad: "meses" }` |
| **Condiciones de garantía** | `String` | `"Cubre defectos de fabricación..."` |
| **Materiales principales** | `Array<String>` | `["Aluminio", "Plástico"]` |
| **Características técnicas** | `Object` | `{ procesador: "Intel i5", nucleos: 10, frecuencia: "4.4 GHz" }` |
| **Especificaciones** | `Object` | `{ pantalla: "15.6 pulgadas", resolucion: "1920x1080" }` |
| **Contenido del paquete** | `Array<String>` | `["Laptop", "Cargador", "Manual"]` |
| **Dimensiones generales** | `Object` | `{ largo: 35.9, ancho: 23.7, alto: 1.8, unidad: "cm" }` |
| **Peso** | `Number / Object` | `{ valor: 1.85, unidad: "kg" }` |
| **Unidad de medida** | `String` | `"unidad"` |
| **Edad recomendada** | `Object / String` | `{ minimo: 12, maximo: null, unidad: "años" }` |
| **Uso recomendado** | `String / Array<String>` | `["Uso académico", "Trabajo", "Ofimática"]` |
| **Instrucciones de uso** | `String` | `"Conectar el cargador antes del primer uso..."` |
| **Advertencias** | `Array<String>` | `["No exponer al agua", "Mantener fuera del alcance de niños"]` |
| **Certificaciones** | `Array<Object>` | `[{ nombre: "CE", organismo: "European Commission" }]` |
| **Código de fabricante / MPN** | `String` | `"82SF00XXUS"` |
| **Código universal del producto (UPC, EAN, GTIN)** | `String` | `"0196801234567"` |
| **Información nutricional — alimentos** | `Object` | `{ calorias: 250, proteinas: 8, grasas: 5, carbohidratos: 40, unidad: "por 100g" }` |
| **Ingredientes — alimentos/cosméticos** | `Array<String>` | `["Agua", "Harina", "Azúcar", "Sal"]` |
| **Compatibilidad — electrónicos, accesorios, repuestos** | `Array<String>` | `["iPhone 15", "iPhone 15 Pro"]` |
| **Sistema operativo compatible** | `Array<String>` | `["Windows 11", "Ubuntu 24.04"]` |
| **Potencia / voltaje — electrónicos** | `Object` | `{ potencia: 65, unidadPotencia: "W", voltaje: 110, unidadVoltaje: "V" }` |
| **Tipo de producto** | `String` | `"Laptop"` |
| **Características destacadas** | `Array<String>` | `["Pantalla Full HD", "SSD de 512 GB", "Wi-Fi 6"]` |
| **Etiquetas o tags** | `Array<String>` | `["laptop", "lenovo", "oficina", "estudiante"]` |

## Tabla 2 — Variantes del producto

| Característica | Tipo de dato | Estructura aproximada |
| --- | --- | --- |
| **Color** | `String / Object` | `"Negro"` o `{ nombre: "Negro", codigoHex: "#000000" }` |
| **Talla** | `String` | `"M"` |
| **Tamaño** | `String / Object` | `"15.6 pulgadas"` |
| **Capacidad** | `Number / Object` | `{ valor: 500, unidad: "ml" }` |
| **Memoria RAM** | `Number / Object` | `{ valor: 16, unidad: "GB" }` |
| **Almacenamiento** | `Number / Object` | `{ valor: 512, unidad: "GB", tipo: "SSD" }` |
| **Peso de presentación** | `Number / Object` | `{ valor: 500, unidad: "g" }` |
| **Volumen** | `Number / Object` | `{ valor: 1.5, unidad: "L" }` |
| **Dimensiones** | `Object` | `{ largo: 30, ancho: 20, alto: 5, unidad: "cm" }` |
| **Sabor** | `String` | `"Chocolate"` |
| **Aroma** | `String` | `"Vainilla"` |
| **Fragancia** | `String` | `"Floral"` |
| **Diseño / estampado** | `String / Object` | `"Rayas"` o `{ tipo: "Estampado", nombre: "Rayas azules" }` |
| **Material** | `String` | `"Algodón"` |
| **Acabado** | `String` | `"Mate"` |
| **Modelo específico** | `String` | `"iPhone 17 Pro Max 256GB"` |
| **Voltaje** | `Number / Object` | `{ valor: 110, unidad: "V" }` |
| **Potencia** | `Number / Object` | `{ valor: 1500, unidad: "W" }` |
| **Presentación** | `String / Object` | `"Paquete"` o `{ tipo: "Caja", descripcion: "Caja de 12 unidades" }` |
| **Cantidad por paquete** | `Number` | `12` |
| **Número de unidades** | `Number` | `1` |
| **Edición** | `String` | `"Edición limitada"` |
| **Compatibilidad específica** | `Array<String>` | `["iPhone 15 Pro", "iPhone 15 Pro Max"]` |
| **Configuración** | `Object` | `{ ram: "16GB", almacenamiento: "512GB", procesador: "Intel i7" }` |
| **Código SKU** | `String` | `"LAP-LEN-I7-16-512-GRY"` |
| **Código de barras** | `String` | `"7501234567890"` |
| **Porcentaje de descuento** | `Number (entero, 0–100, %)` | `10` |
