# AGENTS.md

Instrucciones compartidas para cualquier agente que trabaje en este repositorio: Claude Code, Codex CLI, Pi o cualquier otra herramienta que lea este archivo. Si existe `CLAUDE.md` en este mismo directorio, léelo completo antes de trabajar: ahí vive el contexto propio del proyecto (sus líneas `@ruta` son importaciones de Claude Code; para el resto de herramientas son rutas que debes abrir). Las reglas propias del proyecto se escriben debajo del bloque; lo reemplazan sólo cuando lo dicen por escrito, nunca en silencio.

<!-- agentic-framework:git-discipline v3 start — bloque gestionado por cli/update-skills.sh del Agentic Framework: no lo edites aquí, edita la plantilla. Para congelarlo en este proyecto usa la misma marca de override local que los skills (ver cli/update-skills.sh). -->
## Disciplina de Git (obligatoria para todo agente)

### 1. Cada cambio atómico es un commit, y se sube
Una iteración es cualquiera de estas: un ítem de `tasks/todo.md` marcado como hecho, un ciclo de tests rojo→verde, un fix aplicado y verificado, o un documento actualizado. Al cerrarla: `git add <rutas explícitas>`, `git commit`, y `git push` de la rama de trabajo (si el entorno no tiene red, el push es lo primero al recuperarla). Control: si `git status` muestra más de un cambio lógico sin commitear, ya te pasaste — commitea por separado. Al terminar la sesión no queda trabajo sin commitear: lo que quedó a medias va a la rama de trabajo con prefijo `wip:` y su estado queda anotado en `tasks/todo.md`.
Un cambio atómico es un fix, una función o un documento que se puede revertir solo: va en su propio commit en cuanto está verificado, no acumulado al cierre de la sesión. Lo que no está pusheado no existe para el Owner ni para otro agente: una sesión que termina con cambios sin commitear o commits sin subir no entregó su trabajo.
Mensajes en inglés, `<tipo>: <por qué>` (feat, fix, refactor, test, docs, infra, chore, wip). Commits nuevos siempre: sin `--amend`, sin `--force` sobre ramas compartidas, sin `--no-verify`.

### 2. La documentación viaja en el mismo commit
Todo cambio de comportamiento, API, configuración, comandos o flujo actualiza `README.md` y el documento afectado en el mismo commit o PR. README mínimo: qué es, cómo se instala y se corre, cómo se prueba, cómo se despliega. Si el repo no tiene README, se crea en el primer commit que lo toque. Un README desactualizado miente con autoridad.

### 3. Roadmap, pendientes y lecciones viven en git; cada hallazgo es un issue
- `tasks/todo.md`: plan activo con casillas (`- [ ]` / `- [x]`) y backlog de lo no iniciado. Un pendiente descubierto durante el trabajo se anota ahí en el mismo commit que lo descubre.
- `tasks/lessons.md`: después de cada corrección del Owner, la regla que evita repetirla.
- Todo hallazgo que no se resuelve en el commit en curso (bug, deuda, riesgo, pendiente) y todo Change Request del Owner se registra como issue de GitHub en el momento en que aparece: `gh issue create --title "<qué>" --body "<dónde, evidencia, cómo se detectó>"`. El commit y el PR que lo resuelven lo citan (`Refs #N`, `Closes #N`) y `tasks/todo.md` lleva el número. Sin red: se anota en `tasks/todo.md` con la marca `(issue pendiente)` y se crea al recuperarla. Un pendiente que sólo quedó en la conversación está perdido.
Prueba de aceptación: otro agente, con otra herramienta, abre el repo en frío y reconstruye dónde quedó el trabajo sin preguntar.

### 4. Los repos nuevos nacen privados
`gh repo create <owner>/<nombre> --private` (con `--source . --push` si el repo local ya existe). Siempre no interactivo: sin flag de visibilidad `gh` falla o pregunta, y la respuesta correcta es siempre privado. Hacerlo público (`gh repo edit --visibility public`) requiere pedido explícito del Owner en la sesión. Codex y Pi no crean repos por sí mismos: todo pasa por `gh`/`git`, así que la regla es la misma en cualquier herramienta.

### 5. Cada tarea en su worktree y su rama; las ramas compartidas sólo se mueven por Pull Request
- Cada tarea trabaja en su propio worktree y su propia rama, creados desde `main` actualizado: `git fetch origin && git worktree add .worktrees/<tema> -b feat/<tema> origin/main` (o `fix/<tema>`). El checkout principal se queda en la rama por defecto y limpio; nadie trabaja ahí ni en un worktree o una rama que abrió otro agente.
- Los worktrees viven dentro del repo (`.worktrees/`) o donde los cree el harness (Claude Code, Orca); nunca como carpetas hermanas del repo ni en la raíz de la carpeta de proyectos. Quien crea un worktree lo cierra con `git worktree remove` cuando su PR se integra; la rama queda en el remoto.
- Trabaja en `feat/<tema>` o `fix/<tema>` creada desde `main` (o la rama por defecto del repo), o desde `staging` si depende de algo que sólo está ahí.
- Hay staging si existe `origin/staging` (`git fetch` y `git branch -r`) o si este archivo lo declara. Con staging: `feat/*` → PR a `staging` → verificación → PR de `staging` a `main`. Sin staging: `feat/*` → PR a `main`.
- El agente abre el PR (`gh pr create --base <destino>`); el merge a producción lo aprueba el Owner, salvo que este archivo documente otra cosa. Nada de `git push` directo ni merge local a `main`, `staging` o la rama de producción.
- Excepción documentada: si este archivo declara que `staging` es de larga vida (acumula cambios sin promover), la promoción a producción es cherry-pick de SHAs concretos y nunca merge `staging→main`. Ante la duda entre mergear todo o elegir commits: elige commits.

### 6. Varios agentes, un orquestador
Cuando más de un agente trabaja en el mismo repo, uno orquesta: reparte tareas que no se pisan (archivos y ramas distintos) y es el único que integra los PR en la rama compartida. Los demás entregan por PR desde su worktree: no mergean, no tocan ramas ajenas y no editan en paralelo un archivo que otro tiene abierto. Antes de escribir, revisa los PR abiertos (`gh pr list`) y, donde exista un bus de agentes, quién está trabajando; si alguien ya toca esos archivos, se coordina con el orquestador en vez de avanzar en paralelo.
<!-- agentic-framework:git-discipline end -->
