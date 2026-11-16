# Lecciones aprendidas

Sin lecciones registradas todavía. Después de cada corrección del usuario, agregar acá el patrón que la previene — ver `AGENTS.md` → Disciplina de Git.

**Formato.** Cada lección es un bloque que empieza con un encabezado de nivel 2. Las dos últimas líneas del bloque dicen si la lección sirve solo a este proyecto o a toda la flota:

```
## 2026-09-11 — Título corto de la lección
Qué pasó y qué regla lo previene, en una o dos líneas.
promover: no
alcance:
```

`promover:` vale `sí` o `no`. **El default es `no`**: un bloque sin marca cuenta como `no` y eso está bien — la mayoría de las lecciones son locales. Solo con `promover: sí` hay que escribir `alcance:`, el archivo del framework donde iría la regla:

- `core/skills/<área>/<archivo>.md`, con `<área>` ∈ `memory`, `process`, `conventions`, `stacks`
- `dotclaude/CLAUDE.md`

**Antes de marcar `sí`, las tres preguntas.** Una lección local corrige un hecho de este proyecto (dónde vive algo, qué comando usa, qué contraparte lo edita); una regla de flota corrige un comportamiento del agente que no depende del repo en el que está parado.

1. **Portabilidad** — ¿la regla sigue siendo cierta en un repo de otro stack? Si hay que cambiar una palabra (una ruta interna, un servicio, una persona, una URL, un secreto) para que aplique, es local: `no`.
2. **Recurrencia** — ¿el mismo patrón ya apareció en otro repo, o la corrección dijo explícitamente que aplica a todos los proyectos?
3. **Destino y tamaño** — ¿el archivo de `alcance:` existe y la regla cabe en tres líneas dentro de una sección que ya está ahí? Si necesita un archivo nuevo, no es una promoción: es un skill nuevo, con su propio PR.

Marcar `sí` no promueve nada por sí solo: `cli/harvest-lessons.sh` del framework recolecta las marcas de toda la flota y arma el cuerpo de un PR con la evidencia de cada candidata. Quien revisa ese PR aplica las tres preguntas y decide. Marcar de más solo alarga el PR; nunca cambia una regla de la flota.
