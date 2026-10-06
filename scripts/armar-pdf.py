#!/usr/bin/env python3
"""
Convierte un Markdown de docs/ en un PDF con la marca de Orbital.

    ./scripts/armar-pdf.py docs/documentacion-del-proyecto.md

El Markdown es la fuente: es lo que se edita, lo que se versiona y lo que se
importa a Notion. El HTML es un intermedio descartable y el PDF, la salida.
Así no hay dos documentos que se puedan contradecir.

Necesita `markdown` (pip) y Google Chrome para imprimir.
"""

import html
import re
import subprocess
import sys
from pathlib import Path

import markdown

# El mismo lenguaje visual del manual de despliegue: violeta de la marca,
# tipografía con buen soporte de acentos y cortes de página que no parten
# tablas ni bloques de código al medio.
ESTILO = """
@page { size: A4; margin: 20mm 17mm 18mm; }
@page :first { margin: 0; }

* { box-sizing: border-box; }

body {
  margin: 0;
  font-family: "DejaVu Sans", system-ui, sans-serif;
  font-size: 10.5pt; line-height: 1.6; color: #1c1c21;
}

code, pre { font-family: "DejaVu Sans Mono", ui-monospace, monospace; }

.portada {
  height: 297mm; display: flex; flex-direction: column; justify-content: center;
  page-break-after: always;
  background: linear-gradient(160deg, #1c0b2e 0%, #2d1548 55%, #0a0118 100%);
  color: #fff; padding: 0 24mm;
}
.portada .marca { display: flex; align-items: center; gap: 13px; margin-bottom: 44px; }
.portada h1 { font-size: 34pt; line-height: 1.05; margin: 0 0 14px; font-weight: 600; color: #fff; }
.portada .bajada { color: #c4b5fd; font-size: 12.5pt; margin: 0; max-width: 125mm; line-height: 1.5; }
.portada .pie { margin-top: 52px; font-size: 9.5pt; color: #a78bfa; }

h1 { font-size: 18pt; color: #2d1548; margin: 0 0 10px; page-break-after: avoid; }

h2 {
  font-size: 15pt; margin: 28px 0 10px; color: #2d1548;
  border-bottom: 2px solid #e9d5ff; padding-bottom: 6px;
  page-break-after: avoid; page-break-before: auto;
}

h3 { font-size: 11.5pt; margin: 20px 0 7px; color: #4c1d95; page-break-after: avoid; }

p { margin: 0 0 10px; }
strong { color: #2d1548; }

/* Código suelto dentro de un párrafo. */
:not(pre) > code {
  background: #f3eefb; color: #4c1d95; padding: 1px 4px;
  border-radius: 3px; font-size: 9.2pt;
}

pre {
  background: #f6f3fb; border: 1px solid #e4dcf3; border-left: 3px solid #a855f7;
  border-radius: 5px; padding: 10px 13px; font-size: 8.8pt; line-height: 1.5;
  white-space: pre-wrap; word-break: break-word; margin: 9px 0 12px;
  page-break-inside: avoid;
}
pre code { background: none; color: inherit; padding: 0; font-size: inherit; }

blockquote {
  margin: 10px 0; padding: 9px 14px; background: #fff8e6;
  border-left: 3px solid #e0a800; page-break-inside: avoid;
}
blockquote p { margin: 0; font-size: 9.8pt; }

/* Las tablas largas SÍ se parten entre páginas: con `avoid` empujaban la
   tabla entera a la hoja siguiente y dejaban media página en blanco. Lo que
   no se parte es una fila, y el encabezado se repite arriba de cada pedazo. */
table {
  width: 100%; border-collapse: collapse;
  font-size: 9.3pt; margin: 11px 0 15px;
}
thead { display: table-header-group; }
tr { page-break-inside: avoid; }
th, td { border: 1px solid #ddd6ea; padding: 6px 9px; text-align: left; vertical-align: top; }
th { background: #f6f3fb; color: #2d1548; font-weight: 600; }

ul, ol { margin: 0 0 11px; padding-left: 21px; }
li { margin-bottom: 5px; }

hr { border: 0; border-top: 1px solid #e9d5ff; margin: 26px 0; }

a { color: #7c3aed; text-decoration: none; }

/* El cierre en cursiva del final. */
body > p > em:only-child { color: #6b6b76; font-size: 9.5pt; }
"""

ISOTIPO = """<svg width="48" height="48" viewBox="0 0 64 64">
  <circle cx="32" cy="32" r="22" fill="none" stroke="#C4B5FD" stroke-width="10" />
  <circle cx="32" cy="32" r="22" fill="none" stroke="#8B5CF6" stroke-width="10"
          stroke-linecap="round" stroke-dasharray="86.4 138.2" transform="rotate(-90 32 32)" />
  <circle cx="32" cy="32" r="7" fill="#C4B5FD" />
</svg>"""


def partir_portada(texto):
    """Separa el encabezado del documento (título, bajada, firma) del cuerpo.

    Todo lo que va antes del primer `---` es la portada.
    """
    partes = texto.split("\n---\n", 1)
    if len(partes) == 1:
        return "", texto
    return partes[0], partes[1]


def armar_portada(encabezado):
    lineas = [l.strip() for l in encabezado.strip().split("\n") if l.strip()]
    titulo = lineas[0].lstrip("# ").strip()
    bajada = lineas[1].strip("*").strip() if len(lineas) > 1 else ""
    # La firma puede traer un link en Markdown: se limpia a texto plano.
    pie = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", lineas[2]) if len(lineas) > 2 else ""

    return f"""<section class="portada">
  <div class="marca">{ISOTIPO}<span style="font-size:18pt;letter-spacing:.02em">Banco Orbital</span></div>
  <h1>{html.escape(titulo)}</h1>
  <p class="bajada">{html.escape(bajada)}</p>
  <div class="pie">{html.escape(pie)}</div>
</section>"""


def main():
    if len(sys.argv) != 2:
        sys.exit(f"uso: {sys.argv[0]} docs/archivo.md")

    origen = Path(sys.argv[1]).resolve()
    if not origen.exists():
        sys.exit(f"no existe {origen}")

    encabezado, cuerpo = partir_portada(origen.read_text(encoding="utf-8"))

    cuerpo_html = markdown.markdown(
        cuerpo,
        extensions=["tables", "fenced_code", "sane_lists", "attr_list"],
    )

    documento = f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<title>{html.escape(encabezado.strip().split(chr(10))[0].lstrip('# '))}</title>
<style>{ESTILO}</style></head>
<body>
{armar_portada(encabezado)}
{cuerpo_html}
</body></html>"""

    intermedio = origen.with_suffix(".html")
    salida = origen.with_suffix(".pdf")
    intermedio.write_text(documento, encoding="utf-8")

    subprocess.run(
        ["google-chrome", "--headless=new", "--no-sandbox", "--no-pdf-header-footer",
         f"--print-to-pdf={salida}", str(intermedio)],
        check=True, capture_output=True,
    )
    intermedio.unlink()

    print(f"{salida}  ({salida.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
