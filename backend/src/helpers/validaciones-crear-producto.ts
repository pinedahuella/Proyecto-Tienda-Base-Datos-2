import { ErrorValidacion } from './errores';
import { esTextoNoVacio } from './validaciones-perfil';
import { esNombreCaracteristicaValido } from './validaciones-productos';
import { CaracteristicaDefinicion, TipoDato } from '../models/categoria';
import { EntradaCaracteristica, ValorCaracteristica } from '../models/producto';
import { ESTADOS_PRODUCTO_VALIDOS } from '../models/estado-producto';
import {
  CaracteristicaCatalogoPeticion,
  CaracteristicaPersonalizadaPeticion,
} from '../dto/crear-producto';

/**
 * Reglas de POST /vendedor/productos y PATCH /vendedor/productos/:id: los
 * campos propios del producto y la variante, y las dos clases de
 * caracteristica (del catalogo de la categoria, y personalizadas). Las
 * mismas reglas aplican en los dos: crear y editar comparten estas
 * funciones.
 */

const LONGITUD_MAXIMA_NOMBRE_PRODUCTO = 200;
const LONGITUD_MAXIMA_NOMBRE_VARIANTE = 100;
const REGEX_PRECIO = /^\d+(\.\d{1,2})?$/;

export function validarNombreProducto(nombre: unknown): string {
  if (!esTextoNoVacio(nombre)) {
    throw new ErrorValidacion('El nombre del producto es obligatorio');
  }
  if (nombre.length > LONGITUD_MAXIMA_NOMBRE_PRODUCTO) {
    throw new ErrorValidacion(
      `El nombre del producto no puede tener mas de ${LONGITUD_MAXIMA_NOMBRE_PRODUCTO} caracteres`,
    );
  }
  return nombre;
}

export function validarNombreVariante(nombre: unknown): string {
  if (!esTextoNoVacio(nombre)) {
    throw new ErrorValidacion('El nombre de la variante es obligatorio');
  }
  if (nombre.length > LONGITUD_MAXIMA_NOMBRE_VARIANTE) {
    throw new ErrorValidacion(
      `El nombre de la variante no puede tener mas de ${LONGITUD_MAXIMA_NOMBRE_VARIANTE} caracteres`,
    );
  }
  return nombre;
}

export function validarDescripcionVariante(descripcion: unknown): string {
  if (!esTextoNoVacio(descripcion)) {
    throw new ErrorValidacion('La descripcion de la variante es obligatoria');
  }
  return descripcion;
}

/** Para PATCH /vendedor/productos/:id: el estado tiene que ser uno del catalogo. */
export function validarEstadoProducto(estado: unknown): string {
  if (
    typeof estado !== 'string' ||
    !ESTADOS_PRODUCTO_VALIDOS.includes(estado)
  ) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_PRODUCTO_VALIDOS.join(', ')}`,
    );
  }
  return estado;
}

/**
 * Cuando cambia la categoria de un producto (o de una variante) pero no
 * vienen caracteristicas nuevas en la misma peticion, las que ya tenia
 * tienen que seguir siendo validas para la categoria nueva — si alguna ya
 * no aplica, se rechaza la edicion en vez de dejarla huerfana o borrarla
 * en silencio.
 */
export function validarCaracteristicasExistentesContraCategoria(
  existentes: EntradaCaracteristica[] | undefined,
  definiciones: CaracteristicaDefinicion[],
): void {
  if (existentes == null || existentes.length === 0) {
    return;
  }

  for (const existente of existentes) {
    const definicion = definiciones.find((d) => d.nombre === existente.nombre);
    if (definicion == null) {
      throw new ErrorValidacion(
        `"${existente.nombre}" ya no es una caracteristica valida para la nueva categoria`,
      );
    }
  }
}

/** El precio, a diferencia de precio_min/precio_max en las busquedas, es obligatorio y mayor a 0. */
export function validarPrecioObligatorio(valor: unknown): string {
  if (
    typeof valor !== 'string' ||
    !REGEX_PRECIO.test(valor) ||
    Number(valor) <= 0
  ) {
    throw new ErrorValidacion(
      'El precio es obligatorio y debe ser un numero mayor a 0, con hasta 2 decimales',
    );
  }
  return valor;
}

/** imagenes es opcional: si no viene, la variante entra sin ninguna. */
export function validarImagenes(imagenes: unknown): string[] {
  if (imagenes == null) {
    return [];
  }
  if (
    !Array.isArray(imagenes) ||
    !imagenes.every((img) => esTextoNoVacio(img))
  ) {
    throw new ErrorValidacion('imagenes debe ser una lista de URLs de texto');
  }
  return imagenes;
}

/**
 * Valida el valor de una caracteristica del catalogo contra el tipo_dato de
 * su definicion, y lo deja en la forma que se guarda en Mongo.
 */
export function validarValorSegunTipoDato(
  nombreCaracteristica: string,
  valor: unknown,
  tipoDato: TipoDato,
): ValorCaracteristica {
  switch (tipoDato) {
    case 'texto':
      if (!esTextoNoVacio(valor)) {
        throw new ErrorValidacion(`"${nombreCaracteristica}" debe ser texto`);
      }
      return valor;
    case 'entero':
      if (typeof valor !== 'number' || !Number.isInteger(valor)) {
        throw new ErrorValidacion(
          `"${nombreCaracteristica}" debe ser un numero entero`,
        );
      }
      return valor;
    case 'decimal':
      if (typeof valor !== 'number' || Number.isNaN(valor)) {
        throw new ErrorValidacion(
          `"${nombreCaracteristica}" debe ser un numero`,
        );
      }
      return valor;
    case 'booleano':
      if (typeof valor !== 'boolean') {
        throw new ErrorValidacion(
          `"${nombreCaracteristica}" debe ser verdadero o falso`,
        );
      }
      return valor;
    case 'lista':
      if (
        !Array.isArray(valor) ||
        valor.length === 0 ||
        !valor.every((elemento) => esTextoNoVacio(elemento))
      ) {
        throw new ErrorValidacion(
          `"${nombreCaracteristica}" debe ser una lista de texto con al menos un elemento`,
        );
      }
      return valor;
    default:
      throw new ErrorValidacion(
        `"${nombreCaracteristica}" tiene un tipo_dato desconocido`,
      );
  }
}

/**
 * Valida las caracteristicas del catalogo que manda el vendedor contra el
 * menu que ofrece la categoria: el nombre tiene que ser uno de los que la
 * categoria ofrece (ni repetido), y el valor tiene que cumplir el tipo_dato
 * de esa definicion. La unidad no la manda el vendedor: la rellena esta
 * funcion, tomandola de la definicion.
 */
export function validarCaracteristicasCatalogo(
  peticiones: CaracteristicaCatalogoPeticion[] | undefined,
  definiciones: CaracteristicaDefinicion[],
): EntradaCaracteristica[] {
  if (peticiones == null || peticiones.length === 0) {
    return [];
  }

  const nombresVistos = new Set<string>();
  const entradas: EntradaCaracteristica[] = [];

  for (const peticion of peticiones) {
    if (!esTextoNoVacio(peticion?.nombre)) {
      throw new ErrorValidacion('Cada caracteristica necesita un nombre');
    }
    if (nombresVistos.has(peticion.nombre)) {
      throw new ErrorValidacion(
        `La caracteristica "${peticion.nombre}" viene repetida`,
      );
    }
    nombresVistos.add(peticion.nombre);

    const definicion = definiciones.find((d) => d.nombre === peticion.nombre);
    if (definicion == null) {
      throw new ErrorValidacion(
        `"${peticion.nombre}" no es una caracteristica de esta categoria`,
      );
    }

    const valor = validarValorSegunTipoDato(
      peticion.nombre,
      peticion.valor,
      definicion.tipo_dato,
    );

    entradas.push({
      nombre: peticion.nombre,
      valor,
      unidad: definicion.unidad,
    });
  }

  return entradas;
}

/**
 * Valida las caracteristicas personalizadas: no salen de ningun catalogo,
 * asi que solo se revisa que el formato sea razonable (nombre no vacio y no
 * demasiado largo, valor suelto: texto, numero o booleano, nunca un array
 * ni un objeto) — "que no venga todo loco", no mas que eso.
 */
export function validarCaracteristicasPersonalizadas(
  peticiones: CaracteristicaPersonalizadaPeticion[] | undefined,
): EntradaCaracteristica[] {
  if (peticiones == null || peticiones.length === 0) {
    return [];
  }

  const nombresVistos = new Set<string>();
  const entradas: EntradaCaracteristica[] = [];

  for (const peticion of peticiones) {
    if (
      !esTextoNoVacio(peticion?.nombre) ||
      !esNombreCaracteristicaValido(peticion.nombre)
    ) {
      throw new ErrorValidacion(
        'Cada caracteristica personalizada necesita un nombre valido',
      );
    }
    if (nombresVistos.has(peticion.nombre)) {
      throw new ErrorValidacion(
        `La caracteristica personalizada "${peticion.nombre}" viene repetida`,
      );
    }
    nombresVistos.add(peticion.nombre);

    const valor = peticion.valor;
    const esValorSuelto =
      (typeof valor === 'string' && valor.trim() !== '') ||
      typeof valor === 'number' ||
      typeof valor === 'boolean';

    if (!esValorSuelto) {
      throw new ErrorValidacion(
        `El valor de "${peticion.nombre}" debe ser texto, numero o verdadero/falso`,
      );
    }

    entradas.push({ nombre: peticion.nombre, valor, unidad: null });
  }

  return entradas;
}
