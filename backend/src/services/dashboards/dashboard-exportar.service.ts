import { Injectable } from '@nestjs/common';
import ExcelJS from 'exceljs';
import PDFDocument from 'pdfkit';
import {
  DashboardCompleto,
  SECCIONES_DASHBOARD,
  SeccionDashboard,
} from '../../dto/dashboards/dashboard-general';
import { ErrorValidacion } from '../../helpers/errores';

/**
 * El dashboard general en archivo: Excel (una hoja por seccion, con los
 * numeros como numeros para que se puedan sumar) y PDF (las mismas graficas
 * del dashboard dibujadas con PDFKit, sin captura de pantalla, mas las tablas).
 * Los dos los arma `DashboardGeneralService.completo()`; aqui solo se dibuja.
 */

const NOMBRE_SECCION: Record<SeccionDashboard, string> = {
  resumen: 'Resumen',
  ventas: 'Ventas en el tiempo',
  embudo: 'De mirar a comprar',
  categorias: 'Ventas por categoria',
  pagos: 'Cobrado por mes y metodo',
  mapa: 'Cuando se compra',
  vendedores: 'Vendedores',
  productos: 'Productos',
  departamentos: 'Departamentos',
  busquedas: 'Busquedas',
  cancelaciones: 'Cancelaciones',
  pedidos: 'Registro de pedidos',
};

const DIAS = ['Lun', 'Mar', 'Mie', 'Jue', 'Vie', 'Sab', 'Dom'];

/** Las secciones de `?secciones=a,b`, o todas. */
export function leerSecciones(texto?: string | string[]): SeccionDashboard[] {
  const lista = (Array.isArray(texto) ? texto : (texto ?? '').split(','))
    .map((s) => s.trim())
    .filter((s) => s !== '');
  if (lista.length === 0) return [...SECCIONES_DASHBOARD];
  const malas = lista.filter(
    (s) => !(SECCIONES_DASHBOARD as readonly string[]).includes(s),
  );
  if (malas.length > 0) {
    throw new ErrorValidacion(
      `Secciones que no existen: ${malas.join(', ')}. Son ${SECCIONES_DASHBOARD.join(', ')}`,
    );
  }
  return SECCIONES_DASHBOARD.filter((s) => lista.includes(s));
}

const n = (texto: string | number | null | undefined) => Number(texto ?? 0);
const quetzales = (v: string | number) =>
  `Q${n(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const entero = (v: number) => v.toLocaleString('en-US');
const mayuscula = (t: string) => t.charAt(0).toUpperCase() + t.slice(1);
const MESES = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];
/** 2026-10-05 como 5 oct, y 2026-10 como oct 26. */
const fechaCorta = (texto: string) => {
  const [a, m, d] = texto.split('-').map(Number);
  return d ? `${d} ${MESES[m - 1]}` : `${MESES[m - 1]} ${String(a).slice(2)}`;
};
/** Q150 mil, Q1.2 M: para las escalas, donde los centavos estorban. */
const quetzalesCortos = (v: number) =>
  v >= 1_000_000
    ? `Q${(v / 1_000_000).toFixed(1)} M`
    : v >= 10_000
      ? `Q${Math.round(v / 1000)} mil`
      : `Q${Math.round(v).toLocaleString('en-US')}`;
/** El tope de una escala: 1, 2 o 5 por una potencia de 10, arriba del maximo. */
function topeRedondo(max: number): number {
  if (max <= 0) return 1;
  const potencia = 10 ** Math.floor(Math.log10(max));
  return ([1, 2, 5, 10].find((m) => m * potencia >= max) ?? 10) * potencia;
}
/** Los cinco escalones del mapa de calor, los mismos del dashboard. */
const CALOR = ['#eef0f4', '#fde9b8', '#f6c35a', '#d98a1c', '#9c4a0c'];
const porciento = (v: number) => `${(v * 100).toFixed(1)} %`;

/** El cambio contra el periodo anterior, en palabras cortas. */
function cambio(actual: number, anterior: number): string {
  if (anterior === 0)
    return actual === 0 ? 'igual' : 'sin datos del periodo anterior';
  const d = (actual - anterior) / anterior;
  return `${d >= 0 ? '+' : ''}${(d * 100).toFixed(0)} % contra el anterior`;
}

export function nombreArchivo(d: DashboardCompleto, extension: string): string {
  return `dashboard-mesh-${d.periodo.desde}-a-${d.periodo.hasta}.${extension}`;
}

// Colores del PDF: los mismos tonos del panel (--g1 a --g4), en claro.
const TINTA = '#1f2433';
const GRIS = '#6b7280';
const LINEA = '#d9dce5';
const SERIE = [
  '#5b6cf0',
  '#16a37f',
  '#e0912f',
  '#d6455d',
  '#8a63d2',
  '#2d9cdb',
];

@Injectable()
export class DashboardExportarService {
  // ------------------------------------------------------------------ Excel

  async excel(d: DashboardCompleto): Promise<Buffer> {
    const libro = new ExcelJS.Workbook();
    libro.creator = 'Mesh';
    libro.created = new Date();

    const hoja = (
      nombre: string,
      columnas: {
        titulo: string;
        clave: string;
        ancho?: number;
        formato?: string;
      }[],
      filas: Record<string, unknown>[],
    ) => {
      const h = libro.addWorksheet(nombre.slice(0, 31));
      h.columns = columnas.map((c) => ({
        header: c.titulo,
        key: c.clave,
        width: c.ancho ?? 18,
        style: c.formato ? { numFmt: c.formato } : {},
      }));
      h.getRow(1).font = { bold: true };
      h.getRow(1).fill = {
        type: 'pattern',
        pattern: 'solid',
        fgColor: { argb: 'FFE8EAF6' },
      };
      h.views = [{ state: 'frozen', ySplit: 1 }];
      for (const f of filas) h.addRow(f);
      if (filas.length > 0)
        h.autoFilter = {
          from: { row: 1, column: 1 },
          to: { row: 1, column: columnas.length },
        };
      return h;
    };
    const Q = '"Q"#,##0.00';

    const portada = libro.addWorksheet('Periodo');
    portada.columns = [{ width: 34 }, { width: 22 }, { width: 22 }];
    portada.addRow(['Dashboard general de Mesh']).font = {
      bold: true,
      size: 14,
    };
    portada.addRow(['Periodo', d.periodo.desde, d.periodo.hasta]);
    portada.addRow([
      'Periodo anterior',
      d.periodo.anterior_desde,
      d.periodo.anterior_hasta,
    ]);
    portada.addRow([
      'Generado',
      new Date().toLocaleString('es-GT', { timeZone: 'America/Guatemala' }),
    ]);

    if (d.resumen) {
      const a = d.resumen.actual;
      const b = d.resumen.anterior;
      const r = hoja(
        'Resumen',
        [
          { titulo: 'Cifra', clave: 'cifra', ancho: 30 },
          { titulo: 'Este periodo', clave: 'actual', ancho: 18 },
          { titulo: 'Periodo anterior', clave: 'anterior', ancho: 18 },
        ],
        [
          {
            cifra: 'Cobrado (Q)',
            actual: n(a.ingresos),
            anterior: n(b.ingresos),
          },
          { cifra: 'Pedidos', actual: a.pedidos, anterior: b.pedidos },
          {
            cifra: 'Compra promedio (Q)',
            actual: n(a.ticket_promedio),
            anterior: n(b.ticket_promedio),
          },
          {
            cifra: 'Unidades vendidas',
            actual: a.unidades,
            anterior: b.unidades,
          },
          {
            cifra: 'Compradores',
            actual: a.compradores,
            anterior: b.compradores,
          },
          {
            cifra: 'Cuentas nuevas',
            actual: a.clientes_nuevos,
            anterior: b.clientes_nuevos,
          },
          {
            cifra: 'Pedidos cancelados',
            actual: a.cancelados,
            anterior: b.cancelados,
          },
          {
            cifra: 'Tasa de cancelacion',
            actual: a.tasa_cancelacion,
            anterior: b.tasa_cancelacion,
          },
          {
            cifra: 'Reembolsado (Q)',
            actual: n(a.reembolsado),
            anterior: n(b.reembolsado),
          },
          {
            cifra: 'Vendedores con ventas',
            actual: a.vendedores_con_ventas,
            anterior: b.vendedores_con_ventas,
          },
        ],
      );
      for (const fila of [2, 4, 10])
        for (const col of [2, 3]) r.getCell(fila, col).numFmt = Q;
      for (const col of [2, 3]) r.getCell(9, col).numFmt = '0.0%';
    }
    if (d.ventas) {
      hoja(
        'Ventas',
        [
          {
            titulo: `Periodo (${d.periodo.agrupado})`,
            clave: 'periodo',
            ancho: 16,
          },
          { titulo: 'Cobrado (Q)', clave: 'ingresos', formato: Q },
          { titulo: 'Pedidos', clave: 'pedidos' },
          { titulo: 'Unidades', clave: 'unidades' },
        ],
        d.ventas.serie.map((p) => ({ ...p, ingresos: n(p.ingresos) })),
      );
    }
    if (d.embudo) {
      hoja(
        'Embudo',
        [
          { titulo: 'Etapa', clave: 'etapa', ancho: 40 },
          { titulo: 'Cuantos', clave: 'cuantos' },
        ],
        [
          {
            etapa: 'Personas que vieron un producto',
            cuantos: d.embudo.vieron ?? 'sin datos',
          },
          {
            etapa: 'Cuentas que agregaron al carrito',
            cuantos: d.embudo.agregaron ?? 'sin datos',
          },
          { etapa: 'Cuentas que compraron', cuantos: d.embudo.compraron },
          { etapa: 'Pedidos cancelados', cuantos: d.embudo.cancelaron },
        ],
      );
    }
    if (d.categorias) {
      hoja(
        'Categorias',
        [
          { titulo: 'Categoria', clave: 'categoria', ancho: 28 },
          { titulo: 'Vendido (Q)', clave: 'ingresos', formato: Q },
          { titulo: 'Unidades', clave: 'unidades' },
          { titulo: 'Pedidos', clave: 'pedidos' },
        ],
        d.categorias.map((f) => ({ ...f, ingresos: n(f.ingresos) })),
      );
    }
    if (d.pagos) {
      hoja(
        'Pagos por mes',
        [
          { titulo: 'Mes', clave: 'mes' },
          { titulo: 'Metodo', clave: 'metodo', ancho: 26 },
          { titulo: 'Cobrado (Q)', clave: 'ingresos', formato: Q },
          { titulo: 'Pedidos', clave: 'pedidos' },
        ],
        d.pagos.map((f) => ({ ...f, ingresos: n(f.ingresos) })),
      );
    }
    if (d.mapa) {
      const h = hoja(
        'Cuando se compra',
        [
          { titulo: 'Dia', clave: 'dia', ancho: 10 },
          ...Array.from({ length: 24 }, (_, i) => ({
            titulo: `${i}h`,
            clave: `h${i}`,
            ancho: 6,
          })),
        ],
        DIAS.map((dia, i) => {
          const fila: Record<string, unknown> = { dia };
          for (const c of d.mapa!.filter((x) => x.dia_semana === i + 1))
            fila[`h${c.hora}`] = c.pedidos;
          return fila;
        }),
      );
      h.autoFilter = undefined;
    }
    if (d.vendedores) {
      hoja(
        'Vendedores',
        [
          { titulo: 'Vendedor', clave: 'vendedor', ancho: 30 },
          { titulo: 'Vendido (Q)', clave: 'ingresos', formato: Q },
          { titulo: 'Unidades', clave: 'unidades' },
          { titulo: 'Pedidos', clave: 'pedidos' },
          { titulo: 'Nota promedio', clave: 'nota_promedio' },
        ],
        d.vendedores.map((f) => ({ ...f, ingresos: n(f.ingresos) })),
      );
    }
    if (d.productos) {
      hoja(
        'Productos',
        [
          { titulo: 'Producto', clave: 'nombre', ancho: 40 },
          { titulo: 'Vendido (Q)', clave: 'ingresos', formato: Q },
          { titulo: 'Unidades', clave: 'unidades' },
          { titulo: 'Pedidos', clave: 'pedidos' },
        ],
        d.productos.map((f) => ({ ...f, ingresos: n(f.ingresos) })),
      );
    }
    if (d.departamentos) {
      hoja(
        'Departamentos',
        [
          { titulo: 'Departamento', clave: 'departamento', ancho: 24 },
          { titulo: 'Pedidos', clave: 'pedidos' },
          { titulo: 'Vendido (Q)', clave: 'ingresos', formato: Q },
        ],
        d.departamentos.map((f) => ({ ...f, ingresos: n(f.ingresos) })),
      );
    }
    if (d.busquedas) {
      hoja(
        'Busquedas',
        [
          { titulo: 'Periodo', clave: 'periodo', ancho: 14 },
          { titulo: 'Personas que buscaron', clave: 'busquedas', ancho: 22 },
          { titulo: 'Sin resultados', clave: 'sin_resultados', ancho: 16 },
        ],
        d.busquedas.por_dia,
      );
      hoja(
        'Lo mas buscado',
        [
          { titulo: 'Termino', clave: 'termino', ancho: 34 },
          { titulo: 'Personas', clave: 'personas' },
        ],
        d.busquedas.mas_buscadas,
      );
      hoja(
        'Buscado sin resultado',
        [
          { titulo: 'Termino', clave: 'termino', ancho: 34 },
          { titulo: 'Personas', clave: 'personas' },
        ],
        d.busquedas.sin_resultado,
      );
    }
    if (d.cancelaciones) {
      hoja(
        'Cancelaciones',
        [
          { titulo: 'Cuanto paso hasta cancelar', clave: 'tramo', ancho: 30 },
          { titulo: 'Pedidos', clave: 'pedidos' },
        ],
        d.cancelaciones.por_tiempo,
      );
      hoja(
        'Cancelado por categoria',
        [
          { titulo: 'Categoria', clave: 'categoria', ancho: 28 },
          { titulo: 'Pedidos', clave: 'pedidos' },
          { titulo: 'Unidades', clave: 'unidades' },
        ],
        d.cancelaciones.por_categoria,
      );
    }
    if (d.pedidos) {
      hoja(
        'Pedidos',
        [
          { titulo: 'Pedido', clave: 'id_pedido', ancho: 10 },
          { titulo: 'Fecha', clave: 'fecha', ancho: 18 },
          { titulo: 'Cliente', clave: 'cliente', ancho: 26 },
          { titulo: 'Correo', clave: 'correo', ancho: 30 },
          { titulo: 'Estado', clave: 'estado', ancho: 12 },
          { titulo: 'Metodo', clave: 'metodo', ancho: 22 },
          { titulo: 'Pago', clave: 'estado_pago', ancho: 13 },
          { titulo: 'Total (Q)', clave: 'total', formato: Q },
          { titulo: 'Unidades', clave: 'unidades', ancho: 10 },
          { titulo: 'Departamento', clave: 'departamento', ancho: 18 },
        ],
        d.pedidos.map((f) => ({ ...f, total: n(f.total) })),
      );
    }

    return Buffer.from(await libro.xlsx.writeBuffer());
  }

  // -------------------------------------------------------------------- PDF

  pdf(d: DashboardCompleto): Promise<Buffer> {
    const doc = new PDFDocument({
      size: 'A4',
      margin: 42,
      bufferPages: true,
      info: { Title: 'Dashboard general de Mesh', Author: 'Mesh' },
    });
    const partes: Buffer[] = [];
    doc.on('data', (b: Buffer) => partes.push(b));
    const listo = new Promise<Buffer>((resolver) =>
      doc.on('end', () => resolver(Buffer.concat(partes))),
    );

    const ancho =
      doc.page.width - doc.page.margins.left - doc.page.margins.right;
    const izq = doc.page.margins.left;
    const fondo = () => doc.page.height - doc.page.margins.bottom;
    const espacio = (alto: number) => {
      if (doc.y + alto > fondo()) doc.addPage();
    };
    const titulo = (texto: string, despues = 120) => {
      espacio(despues + 40);
      doc
        .moveDown(0.8)
        .font('Helvetica-Bold')
        .fontSize(13)
        .fillColor(TINTA)
        .text(texto, izq);
      doc.moveDown(0.3);
    };
    const nota = (texto: string) =>
      doc
        .font('Helvetica')
        .fontSize(8.5)
        .fillColor(GRIS)
        .text(texto, izq, doc.y, { width: ancho });

    /** Una tabla simple, con la cabecera repetida si cambia de pagina. */
    const tabla = (
      columnas: { titulo: string; ancho: number; derecha?: boolean }[],
      filas: string[][],
    ) => {
      const total = columnas.reduce((s, c) => s + c.ancho, 0);
      const escala = ancho / total;
      const cols = columnas.map((c) => ({ ...c, ancho: c.ancho * escala }));
      const cabecera = () => {
        let x = izq;
        doc.font('Helvetica-Bold').fontSize(8).fillColor(GRIS);
        const y = doc.y;
        for (const c of cols) {
          doc.text(c.titulo, x + 3, y, {
            width: c.ancho - 6,
            align: c.derecha ? 'right' : 'left',
          });
          x += c.ancho;
        }
        doc
          .moveTo(izq, y + 12)
          .lineTo(izq + ancho, y + 12)
          .strokeColor(LINEA)
          .lineWidth(0.8)
          .stroke();
        doc.y = y + 16;
      };
      cabecera();
      doc.font('Helvetica').fontSize(8.5).fillColor(TINTA);
      for (const fila of filas) {
        if (doc.y + 14 > fondo()) {
          doc.addPage();
          cabecera();
          doc.font('Helvetica').fontSize(8.5).fillColor(TINTA);
        }
        let x = izq;
        const y = doc.y;
        fila.forEach((celda, i) => {
          doc.text(celda, x + 3, y, {
            width: cols[i].ancho - 6,
            align: cols[i].derecha ? 'right' : 'left',
            lineBreak: false,
            ellipsis: true,
          });
          x += cols[i].ancho;
        });
        doc.y = y + 13;
      }
      doc.x = izq;
    };

    /** Barras horizontales: una por fila, con su valor al final. */
    const barras = (
      filas: { rotulo: string; valor: number; texto: string }[],
      color = SERIE[0],
    ) => {
      if (filas.length === 0) return nota('Nada en este periodo.');
      const max = Math.max(...filas.map((f) => f.valor), 1);
      const anchoRotulo = 150;
      const anchoTexto = 90;
      const largo = ancho - anchoRotulo - anchoTexto - 10;
      espacio(filas.length * 17 + 6);
      for (const f of filas) {
        const y = doc.y;
        doc
          .font('Helvetica')
          .fontSize(8.5)
          .fillColor(TINTA)
          .text(f.rotulo, izq, y + 2, {
            width: anchoRotulo - 6,
            lineBreak: false,
            ellipsis: true,
          });
        doc
          .roundedRect(izq + anchoRotulo, y + 1, largo, 12, 3)
          .strokeColor(LINEA)
          .lineWidth(0.8)
          .stroke();
        if (f.valor > 0)
          doc
            .roundedRect(
              izq + anchoRotulo + 1.5,
              y + 2.5,
              Math.max(2, (f.valor / max) * (largo - 3)),
              9,
              2,
            )
            .fillColor(color)
            .fill();
        doc
          .fillColor(GRIS)
          .text(f.texto, izq + anchoRotulo + largo + 8, y + 2, {
            width: anchoTexto,
            lineBreak: false,
          });
        doc.y = y + 17;
      }
      doc.x = izq;
    };

    // Portada y periodo
    doc
      .font('Helvetica-Bold')
      .fontSize(20)
      .fillColor(TINTA)
      .text('Dashboard general de Mesh', izq);
    doc
      .font('Helvetica')
      .fontSize(10)
      .fillColor(GRIS)
      .text(
        `Del ${d.periodo.desde} al ${d.periodo.hasta} (${d.periodo.dias} dias), comparado con el ${d.periodo.anterior_desde} al ${d.periodo.anterior_hasta}.`,
      )
      .text(
        `Generado el ${new Date().toLocaleString('es-GT', { timeZone: 'America/Guatemala', dateStyle: 'long', timeStyle: 'short' })}`,
      );

    if (d.resumen) {
      titulo(NOMBRE_SECCION.resumen);
      const a = d.resumen.actual;
      const b = d.resumen.anterior;
      const cifras: [string, string, string][] = [
        [
          'Cobrado',
          quetzales(a.ingresos),
          cambio(n(a.ingresos), n(b.ingresos)),
        ],
        ['Pedidos', entero(a.pedidos), cambio(a.pedidos, b.pedidos)],
        [
          'Compra promedio',
          quetzales(a.ticket_promedio),
          cambio(n(a.ticket_promedio), n(b.ticket_promedio)),
        ],
        [
          'Unidades vendidas',
          entero(a.unidades),
          cambio(a.unidades, b.unidades),
        ],
        [
          'Compradores',
          entero(a.compradores),
          cambio(a.compradores, b.compradores),
        ],
        [
          'Cuentas nuevas',
          entero(a.clientes_nuevos),
          cambio(a.clientes_nuevos, b.clientes_nuevos),
        ],
        [
          'Cancelados',
          `${entero(a.cancelados)} (${porciento(a.tasa_cancelacion)})`,
          cambio(a.cancelados, b.cancelados),
        ],
        [
          'Reembolsado',
          quetzales(a.reembolsado),
          cambio(n(a.reembolsado), n(b.reembolsado)),
        ],
      ];
      const columnas = 4;
      const anchoCaja = (ancho - (columnas - 1) * 8) / columnas;
      const altoCaja = 54;
      espacio(2 * altoCaja + 16);
      const y0 = doc.y;
      cifras.forEach(([rotulo, valor, delta], i) => {
        const x = izq + (i % columnas) * (anchoCaja + 8);
        const y = y0 + Math.floor(i / columnas) * (altoCaja + 8);
        doc
          .roundedRect(x, y, anchoCaja, altoCaja, 4)
          .strokeColor(LINEA)
          .lineWidth(0.8)
          .stroke();
        doc
          .font('Helvetica')
          .fontSize(7.5)
          .fillColor(GRIS)
          .text(rotulo.toUpperCase(), x + 8, y + 7, { width: anchoCaja - 16 });
        doc
          .font('Helvetica-Bold')
          .fontSize(13)
          .fillColor(TINTA)
          .text(valor, x + 8, y + 19, {
            width: anchoCaja - 16,
            lineBreak: false,
            ellipsis: true,
          });
        doc
          .font('Helvetica')
          .fontSize(7.5)
          .fillColor(GRIS)
          .text(delta, x + 8, y + 38, { width: anchoCaja - 16 });
      });
      doc.y = y0 + 2 * (altoCaja + 8);
      doc.x = izq;
      const hoy = d.resumen.hoy;
      nota(
        `Hoy hay ${entero(hoy.productos_activos)} productos a la venta, ${entero(hoy.vendedores_activos)} vendedores con ofertas activas, ${entero(hoy.cuentas)} cuentas y ${entero(hoy.carritos_abiertos)} carritos abiertos.`,
      );
    }

    if (d.ventas) {
      titulo(`${NOMBRE_SECCION.ventas}, por ${d.periodo.agrupado}`, 180);
      const serie = d.ventas.serie;
      const alto = 150;
      espacio(alto + 30);
      const y0 = doc.y;
      const max = topeRedondo(Math.max(...serie.map((p) => n(p.ingresos)), 0));
      const ejeX = izq + 52;
      const largo = ancho - 52;
      doc.font('Helvetica').fontSize(7).fillColor(GRIS);
      for (let i = 0; i <= 4; i++) {
        const y = y0 + alto - (alto * i) / 4;
        doc
          .moveTo(ejeX, y)
          .lineTo(ejeX + largo, y)
          .strokeColor(LINEA)
          .lineWidth(0.5)
          .stroke();
        doc.text(quetzalesCortos((max * i) / 4), izq, y - 4, {
          width: 48,
          align: 'right',
        });
      }
      if (serie.length > 0) {
        const paso = serie.length > 1 ? largo / (serie.length - 1) : 0;
        const punto = (i: number) =>
          [
            ejeX + i * paso,
            y0 + alto - (n(serie[i].ingresos) / max) * alto,
          ] as const;
        doc.moveTo(...punto(0));
        for (let i = 1; i < serie.length; i++) doc.lineTo(...punto(i));
        doc
          .lineTo(ejeX + (serie.length - 1) * paso, y0 + alto)
          .lineTo(ejeX, y0 + alto)
          .closePath()
          .fillOpacity(0.12)
          .fillColor(SERIE[0])
          .fill()
          .fillOpacity(1);
        doc.moveTo(...punto(0));
        for (let i = 1; i < serie.length; i++) doc.lineTo(...punto(i));
        doc.strokeColor(SERIE[0]).lineWidth(1.6).stroke();
        const cada = Math.max(1, Math.ceil(serie.length / 8));
        doc.fillColor(GRIS).fontSize(7);
        serie.forEach((p, i) => {
          if (i % cada === 0)
            doc.text(
              fechaCorta(p.periodo),
              ejeX + i * paso - 18,
              y0 + alto + 4,
              {
                width: 36,
                align: 'center',
              },
            );
        });
      }
      doc.y = y0 + alto + 18;
      doc.x = izq;
      const totalPedidos = serie.reduce((s, p) => s + p.pedidos, 0);
      nota(
        `${entero(totalPedidos)} pedidos vendidos en el periodo. La linea es lo vendido en quetzales.`,
      );
    }

    if (d.embudo) {
      titulo(NOMBRE_SECCION.embudo, 90);
      const e = d.embudo;
      barras(
        [
          {
            rotulo: 'Vieron un producto',
            valor: e.vieron ?? 0,
            texto: e.vieron == null ? 'sin datos' : entero(e.vieron),
          },
          {
            rotulo: 'Agregaron al carrito',
            valor: e.agregaron ?? 0,
            texto: e.agregaron == null ? 'sin datos' : entero(e.agregaron),
          },
          {
            rotulo: 'Compraron',
            valor: e.compraron,
            texto: entero(e.compraron),
          },
          {
            rotulo: 'Pedidos cancelados',
            valor: e.cancelaron,
            texto: entero(e.cancelaron),
          },
        ],
        SERIE[1],
      );
      if (e.sin_eventos)
        nota('ClickHouse no respondio, las dos primeras etapas no estan.');
      else if (e.eventos_desde && e.eventos_desde > d.periodo.desde)
        nota(
          `Las vistas y los carritos se registran desde el ${e.eventos_desde}. Antes de ese dia hay compras sin vistas, por eso compraron puede pasar a vieron.`,
        );
    }

    if (d.categorias) {
      titulo(NOMBRE_SECCION.categorias, 110);
      barras(
        d.categorias.slice(0, 12).map((f) => ({
          rotulo: f.categoria,
          valor: n(f.ingresos),
          texto: quetzales(f.ingresos),
        })),
        SERIE[0],
      );
    }

    if (d.pagos) {
      titulo(NOMBRE_SECCION.pagos, 190);
      const meses = [...new Set(d.pagos.map((p) => p.mes))];
      const metodos = [...new Set(d.pagos.map((p) => p.metodo))];
      const alto = 140;
      espacio(alto + 40);
      const y0 = doc.y;
      const totalMes = (m: string) =>
        d
          .pagos!.filter((p) => p.mes === m)
          .reduce((s, p) => s + n(p.ingresos), 0);
      const max = Math.max(...meses.map(totalMes), 1);
      const hueco = ancho / Math.max(meses.length, 1);
      const anchoBarra = Math.min(36, hueco * 0.6);
      meses.forEach((m, i) => {
        let base = y0 + alto;
        const x = izq + i * hueco + (hueco - anchoBarra) / 2;
        metodos.forEach((metodo, j) => {
          const v = n(
            d.pagos!.find((p) => p.mes === m && p.metodo === metodo)?.ingresos,
          );
          const h = (v / max) * alto;
          if (h > 0)
            doc
              .rect(x, base - h, anchoBarra, h)
              .fillColor(SERIE[j % SERIE.length])
              .fill();
          base -= h;
        });
        doc
          .font('Helvetica')
          .fontSize(7)
          .fillColor(GRIS)
          .text(fechaCorta(m), izq + i * hueco, y0 + alto + 4, {
            width: hueco,
            align: 'center',
          });
      });
      doc.y = y0 + alto + 18;
      let x = izq;
      metodos.forEach((metodo, j) => {
        doc
          .rect(x, doc.y + 1, 8, 8)
          .fillColor(SERIE[j % SERIE.length])
          .fill();
        doc
          .fillColor(TINTA)
          .fontSize(8)
          .text(mayuscula(metodo), x + 12, doc.y, { lineBreak: false });
        x += doc.widthOfString(mayuscula(metodo)) + 30;
      });
      doc.y += 14;
      doc.x = izq;
    }

    if (d.mapa) {
      titulo(`${NOMBRE_SECCION.mapa}, pedidos por dia y hora`, 150);
      const celda = (ancho - 30) / 24;
      const alto = 15;
      espacio(8 * alto + 20);
      const y0 = doc.y;
      const max = Math.max(...d.mapa.map((c) => c.pedidos), 1);
      DIAS.forEach((dia, i) => {
        doc
          .font('Helvetica')
          .fontSize(7)
          .fillColor(GRIS)
          .text(dia, izq, y0 + i * alto + 3, { width: 28 });
        for (let h = 0; h < 24; h++) {
          const c = d.mapa!.find((x) => x.dia_semana === i + 1 && x.hora === h);
          const t = c ? c.pedidos / max : 0;
          const escalon =
            t <= 0 ? 0 : t < 0.25 ? 1 : t < 0.5 ? 2 : t < 0.8 ? 3 : 4;
          const x = izq + 30 + h * celda;
          const y = y0 + i * alto;
          doc
            .roundedRect(x, y, celda - 1.2, alto - 1.2, 2)
            .fillColor(CALOR[escalon])
            .fill();
          if (c && c.pedidos > 0)
            doc
              .font('Helvetica-Bold')
              .fontSize(6)
              .fillColor(escalon >= 3 ? '#ffffff' : '#4a3508')
              .text(String(c.pedidos), x, y + 4.5, {
                width: celda - 1.2,
                align: 'center',
                lineBreak: false,
              });
        }
      });
      for (let h = 0; h < 24; h += 3)
        doc
          .font('Helvetica')
          .fontSize(7)
          .fillColor(GRIS)
          .text(`${h}h`, izq + 30 + h * celda, y0 + 7 * alto + 3, {
            width: celda * 3,
          });
      doc.y = y0 + 8 * alto + 6;
      doc.x = izq;
      const pico = d.mapa.reduce((m, c) => (c.pedidos > m.pedidos ? c : m), {
        dia_semana: 1,
        hora: 0,
        pedidos: 0,
        ingresos: '0',
      });
      if (pico.pedidos > 0)
        nota(
          `El momento con mas pedidos es el ${DIAS[pico.dia_semana - 1].toLowerCase()} a las ${pico.hora}:00, con ${pico.pedidos}. Hora de Guatemala.`,
        );
    }

    if (d.vendedores) {
      titulo(NOMBRE_SECCION.vendedores, 150);
      tabla(
        [
          { titulo: 'Vendedor', ancho: 4 },
          { titulo: 'Vendido', ancho: 2, derecha: true },
          { titulo: 'Unidades', ancho: 1.3, derecha: true },
          { titulo: 'Pedidos', ancho: 1.3, derecha: true },
          { titulo: 'Nota', ancho: 1, derecha: true },
        ],
        d.vendedores.map((f) => [
          f.vendedor,
          quetzales(f.ingresos),
          entero(f.unidades),
          entero(f.pedidos),
          f.nota_promedio == null ? '-' : f.nota_promedio.toFixed(1),
        ]),
      );
    }
    if (d.productos) {
      titulo(NOMBRE_SECCION.productos, 150);
      tabla(
        [
          { titulo: 'Producto', ancho: 5 },
          { titulo: 'Vendido', ancho: 2, derecha: true },
          { titulo: 'Unidades', ancho: 1.3, derecha: true },
          { titulo: 'Pedidos', ancho: 1.3, derecha: true },
        ],
        d.productos.map((f) => [
          f.nombre,
          quetzales(f.ingresos),
          entero(f.unidades),
          entero(f.pedidos),
        ]),
      );
    }
    if (d.departamentos) {
      titulo(NOMBRE_SECCION.departamentos, 110);
      barras(
        d.departamentos.slice(0, 12).map((f) => ({
          rotulo: f.departamento,
          valor: n(f.ingresos),
          texto: `${quetzales(f.ingresos)}`,
        })),
        SERIE[4],
      );
    }
    if (d.busquedas) {
      titulo(NOMBRE_SECCION.busquedas, 120);
      const total = d.busquedas.por_dia.reduce((s, p) => s + p.busquedas, 0);
      const sin = d.busquedas.por_dia.reduce((s, p) => s + p.sin_resultados, 0);
      nota(
        `${entero(total)} personas buscaron algo en el periodo y ${entero(sin)} no encontraron nada.`,
      );
      doc.moveDown(0.4);
      barras(
        d.busquedas.mas_buscadas.map((f) => ({
          rotulo: f.termino,
          valor: f.personas,
          texto: `${f.personas} personas`,
        })),
        SERIE[5],
      );
      if (d.busquedas.sin_resultado.length > 0) {
        doc.moveDown(0.4);
        doc
          .font('Helvetica-Bold')
          .fontSize(9.5)
          .fillColor(TINTA)
          .text('Se busca y no se encuentra', izq);
        doc.moveDown(0.2);
        barras(
          d.busquedas.sin_resultado.map((f) => ({
            rotulo: f.termino,
            valor: f.personas,
            texto: `${f.personas} personas`,
          })),
          SERIE[3],
        );
      }
    }
    if (d.cancelaciones) {
      titulo(NOMBRE_SECCION.cancelaciones, 110);
      barras(
        d.cancelaciones.por_tiempo.map((f) => ({
          rotulo: f.tramo,
          valor: f.pedidos,
          texto: `${f.pedidos} pedidos`,
        })),
        SERIE[3],
      );
      if (d.cancelaciones.por_categoria.length > 0) {
        doc.moveDown(0.4);
        tabla(
          [
            { titulo: 'Categoria', ancho: 4 },
            { titulo: 'Pedidos', ancho: 1.5, derecha: true },
            { titulo: 'Unidades', ancho: 1.5, derecha: true },
          ],
          d.cancelaciones.por_categoria.map((f) => [
            f.categoria,
            entero(f.pedidos),
            entero(f.unidades),
          ]),
        );
      }
    }
    if (d.pedidos) {
      titulo(NOMBRE_SECCION.pedidos, 120);
      const visibles = d.pedidos.slice(0, 400);
      tabla(
        [
          { titulo: 'Pedido', ancho: 1 },
          { titulo: 'Fecha', ancho: 2.1 },
          { titulo: 'Cliente', ancho: 3 },
          { titulo: 'Estado', ancho: 1.5 },
          { titulo: 'Metodo', ancho: 2.2 },
          { titulo: 'Total', ancho: 1.7, derecha: true },
        ],
        visibles.map((f) => [
          String(f.id_pedido),
          f.fecha,
          f.cliente,
          f.estado,
          f.metodo ?? '-',
          quetzales(f.total),
        ]),
      );
      if (d.pedidos.length > visibles.length)
        nota(
          `Se muestran los ${visibles.length} mas nuevos de ${d.pedidos.length}. Todos estan en el Excel.`,
        );
    }

    // Numero de pagina al pie
    const paginas = doc.bufferedPageRange();
    for (let i = 0; i < paginas.count; i++) {
      doc.switchToPage(i);
      // Debajo del margen PDFKit abre otra pagina al escribir: se quita el
      // margen de abajo solo para el pie.
      const margen = doc.page.margins.bottom;
      doc.page.margins.bottom = 0;
      doc
        .font('Helvetica')
        .fontSize(7.5)
        .fillColor(GRIS)
        .text(
          `Mesh, dashboard general · ${i + 1} de ${paginas.count}`,
          izq,
          doc.page.height - 28,
          { width: ancho, align: 'center', lineBreak: false },
        );
      doc.page.margins.bottom = margen;
    }
    doc.end();
    return listo;
  }
}
