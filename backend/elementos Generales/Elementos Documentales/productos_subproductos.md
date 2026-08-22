| Característica                                                     | Tipo de dato             | Estructura aproximada                                                               |
| ------------------------------------------------------------------ | ------------------------ | ----------------------------------------------------------------------------------- |
| **Nombre del producto**                                            | `String`                 | `"Laptop Lenovo IdeaPad 5"`                                                         |
| **Descripción**                                                    | `String`                 | `"Laptop para uso profesional y académico..."`                                      |
| **Marca**                                                          | `String`                 | `"Lenovo"`                                                                          |
| **Modelo**                                                         | `String`                 | `"IdeaPad 5 15IAL7"`                                                                |
| **Categoría**                                                      | `Object / String`        | `{ id: "cat_001", nombre: "Electrónicos" }`                                         |
| **Subcategoría**                                                   | `Object / String`        | `{ id: "sub_001", nombre: "Laptops" }`                                              |
| **Fabricante**                                                     | `String`                 | `"Lenovo Group Limited"`                                                            |
| **País de origen**                                                 | `String`                 | `"China"`                                                                           |
| **Garantía**                                                       | `Boolean / Object`       | `{ disponible: true, tipo: "Fabricante" }`                                          |
| **Duración de la garantía**                                        | `Number / Object`        | `{ valor: 12, unidad: "meses" }`                                                    |
| **Condiciones de garantía**                                        | `String`                 | `"Cubre defectos de fabricación..."`                                                |
| **Materiales principales**                                         | `Array<String>`          | `["Aluminio", "Plástico"]`                                                          |
| **Características técnicas**                                       | `Object`                 | `{ procesador: "Intel i5", nucleos: 10, frecuencia: "4.4 GHz" }`                    |
| **Especificaciones**                                               | `Object`                 | `{ pantalla: "15.6 pulgadas", resolucion: "1920x1080" }`                            |
| **Contenido del paquete**                                          | `Array<String>`          | `["Laptop", "Cargador", "Manual"]`                                                  |
| **Dimensiones generales**                                          | `Object`                 | `{ largo: 35.9, ancho: 23.7, alto: 1.8, unidad: "cm" }`                             |
| **Peso**                                                           | `Number / Object`        | `{ valor: 1.85, unidad: "kg" }`                                                     |
| **Unidad de medida**                                               | `String`                 | `"unidad"`                                                                          |
| **Edad recomendada**                                               | `Object / String`        | `{ minimo: 12, maximo: null, unidad: "años" }`                                      |
| **Uso recomendado**                                                | `String / Array<String>` | `["Uso académico", "Trabajo", "Ofimática"]`                                         |
| **Instrucciones de uso**                                           | `String`                 | `"Conectar el cargador antes del primer uso..."`                                    |
| **Advertencias**                                                   | `Array<String>`          | `["No exponer al agua", "Mantener fuera del alcance de niños"]`                     |
| **Certificaciones**                                                | `Array<Object>`          | `[{ nombre: "CE", organismo: "European Commission" }]`                              |
| **Código de fabricante / MPN**                                     | `String`                 | `"82SF00XXUS"`                                                                      |
| **Código universal del producto (UPC, EAN, GTIN)**                 | `String`                 | `"0196801234567"`                                                                   |
| **Información nutricional — alimentos**                            | `Object`                 | `{ calorias: 250, proteinas: 8, grasas: 5, carbohidratos: 40, unidad: "por 100g" }` |
| **Ingredientes — alimentos/cosméticos**                            | `Array<String>`          | `["Agua", "Harina", "Azúcar", "Sal"]`                                               |
| **Compatibilidad — electrónicos, accesorios, repuestos**           | `Array<String>`          | `["iPhone 15", "iPhone 15 Pro"]`                                                    |
| **Sistema operativo compatible**                                   | `Array<String>`          | `["Windows 11", "Ubuntu 24.04"]`                                                    |
| **Potencia / voltaje — electrónicos**                              | `Object`                 | `{ potencia: 65, unidadPotencia: "W", voltaje: 110, unidadVoltaje: "V" }`           |
| **Tipo de producto**                                               | `String`                 | `"Laptop"`                                                                          |
| **Características destacadas**                                     | `Array<String>`          | `["Pantalla Full HD", "SSD de 512 GB", "Wi-Fi 6"]`                                  |
| **Etiquetas o tags**                                               | `Array<String>`          | `["laptop", "lenovo", "oficina", "estudiante"]`                                     |
| **Imágenes generales del producto**                                | `Array<Object>`          | `[{ url: "...", descripcion: "Vista frontal", orden: 1 }]`                          |
| **Documentos asociados — manuales, fichas técnicas, certificados** | `Array<Object>`          | `[{ tipo: "manual", nombre: "Manual.pdf", url: "..." }]`                            |

| Característica                       | Tipo de dato                 | Estructura aproximada                                                |
| ------------------------------------ | ---------------------------- | -------------------------------------------------------------------- |
| **Color**                            | `String / Object`            | `"Negro"` o `{ nombre: "Negro", codigoHex: "#000000" }`              |
| **Talla**                            | `String`                     | `"M"`                                                                |
| **Tamaño**                           | `String / Object`            | `"15.6 pulgadas"`                                                    |
| **Capacidad**                        | `Number / Object`            | `{ valor: 500, unidad: "ml" }`                                       |
| **Memoria RAM**                      | `Number / Object`            | `{ valor: 16, unidad: "GB" }`                                        |
| **Almacenamiento**                   | `Number / Object`            | `{ valor: 512, unidad: "GB", tipo: "SSD" }`                          |
| **Peso de presentación**             | `Number / Object`            | `{ valor: 500, unidad: "g" }`                                        |
| **Volumen**                          | `Number / Object`            | `{ valor: 1.5, unidad: "L" }`                                        |
| **Dimensiones**                      | `Object`                     | `{ largo: 30, ancho: 20, alto: 5, unidad: "cm" }`                    |
| **Sabor**                            | `String`                     | `"Chocolate"`                                                        |
| **Aroma**                            | `String`                     | `"Vainilla"`                                                         |
| **Fragancia**                        | `String`                     | `"Floral"`                                                           |
| **Diseño / estampado**               | `String / Object`            | `"Rayas"` o `{ tipo: "Estampado", nombre: "Rayas azules" }`          |
| **Material**                         | `String`                     | `"Algodón"`                                                          |
| **Acabado**                          | `String`                     | `"Mate"`                                                             |
| **Modelo específico**                | `String`                     | `"iPhone 17 Pro Max 256GB"`                                          |
| **Voltaje**                          | `Number / Object`            | `{ valor: 110, unidad: "V" }`                                        |
| **Potencia**                         | `Number / Object`            | `{ valor: 1500, unidad: "W" }`                                       |
| **Presentación**                     | `String / Object`            | `"Paquete"` o `{ tipo: "Caja", descripcion: "Caja de 12 unidades" }` |
| **Cantidad por paquete**             | `Number`                     | `12`                                                                 |
| **Número de unidades**               | `Number`                     | `1`                                                                  |
| **Edición**                          | `String`                     | `"Edición limitada"`                                                 |
| **Compatibilidad específica**        | `Array<String>`              | `["iPhone 15 Pro", "iPhone 15 Pro Max"]`                             |
| **Configuración**                    | `Object`                     | `{ ram: "16GB", almacenamiento: "512GB", procesador: "Intel i7" }`   |
| **Código SKU**                       | `String`                     | `"LAP-LEN-I7-16-512-GRY"`                                            |
| **Código de barras**                 | `String`                     | `"7501234567890"`                                                    |
| **Precio**                           | `Number / Decimal128`        | `7499.99`                                                            |
| **Precio promocional**               | `Number / Decimal128 / null` | `6999.99`                                                            |
| **Estado de disponibilidad**         | `String / Enum`              | `"disponible"`                                                       |
| **Stock**                            | `Number`                     | `25`                                                                 |
| **Imagen específica de la variante** | `Array<Object>`              | `[{ url: "...", descripcion: "Color negro", orden: 1 }]`             |
