<p align="center"><img src="icon/app.svg" width="128" alt="Logo de Guachiman"></p>

# Guachiman

App nativa de la barra de menú de macOS (Swift + AppKit, macOS 13+) que vigila la RAM y la CPU de todas tus apps, además de tus sesiones de Claude Code y los procesos huérfanos, y te avisa con notificaciones. Sin ícono en el Dock, sin ventana, sin dependencias.

## Qué hace

- Detecta sesiones de Claude Code (terminal y Claude Desktop): procesos cuyo ejecutable o `argv[0]` se llama exactamente `claude` (las instalaciones de terminal viven en `~/.local/share/claude/versions/<ver>`, así que solo `argv[0]` dice `claude`).
- Suma la RAM (RSS) de cada sesión y de todos sus procesos hijos, y la etiqueta con el nombre de la carpeta de trabajo.
- Cada sesión se rotula con su título de Claude Code (el de la pestaña de la terminal; `/rename` manda sobre el automático), leído de forma perezosa solo al abrir el menú, al avisar o en `--once`; sin título muestra la carpeta.
- Muestra en el menú barras de RAM en uso y CPU con color de calor (verde → amarillo → rojo) y las sesiones ordenadas por consumo. Cada fila (sesiones, huérfanos y las 5 apps) lleva un círculo de color y un botón para detenerla (ver "Colores y detener").
- Vigila todas las demás apps: agrupa los procesos por app (el `.app` más externo de la ruta del ejecutable, p. ej. los helpers de Google Chrome cuentan como "Google Chrome"; un proceso fuera de un `.app` es su propio grupo) y suma su RAM y su CPU (% de un núcleo, calculado entre dos sondeos). Los procesos de sesiones de Claude y de huérfanos no se repiten ahí. El menú lista las 5 apps que más RAM usan.
- Te notifica cuando una sesión, una app (solo por CPU) o el sistema superan los umbrales; la RAM de las apps solo aparece en el aviso de memoria libre baja. Las apps solo se cierran si tú lo pides con el botón de detener.
- Lee los procesos con `libproc` y `sysctl`; no lanza `ps`.

## Notificaciones

Son solo nativas (`UNUserNotificationCenter`); la app nunca usa `osascript`, así que ningún aviso aparece atribuido a "Script Editor". Si las notificaciones no están autorizadas, el menú muestra "Activar notificaciones", que abre Ajustes del Sistema > Notificaciones. El estado se vuelve a revisar en cada sondeo, así que el ítem desaparece cuando las activas. Mientras no estén autorizadas, el ícono rojo sigue indicando la alerta.

Para comprobar que funcionan, ejecuta `make notify-test`: abre la app con `--notify-test` y, al resolverse la autorización, envía "Prueba: Guachiman puede notificarte".

## Huérfanos

Un candidato a huérfano es un proceso con `ppid == 1` cuyo nombre (del ejecutable o de `argv[0]`, también con sufijo tras guion, como `next-server`) es `node`, `vitest`, `next` o `playwright`, y que no pertenece a ninguna sesión de Claude. Su RAM suma la del proceso y la de todos sus descendientes. Se avisa cuando supera 500 MB de forma sostenida por 60 s, con el mismo enfriamiento que el resto de alertas. `--once` también los lista.

## Colores y detener

Cada fila del menú (sesiones de Claude, huérfanos y las 5 apps que más consumen) empieza con un círculo de color. La CPU de sesiones y huérfanos es la suma de su árbol de procesos, como en las apps. Los valores son instantáneos, salvo el gris:

- **Gris**: inactivo; CPU por debajo de 1 % de forma continua durante los últimos 120 s. Una fila vista hace menos de 120 s no es gris. El gris manda sobre los demás colores, también si usa mucha RAM.
- **Rojo**: supera un umbral (RAM sobre el 15% de la RAM física, o CPU sobre 80% de un núcleo; en huérfanos, RAM sobre 500 MB). El color de las filas es independiente de las notificaciones: una app con mucha RAM se ve roja, pero no genera aviso propio.
- **Amarillo**: al menos el 75 % de alguno de esos umbrales.
- **Verde**: el resto.

Al pasar el cursor sobre una fila, el botón de detener (un cuadrado rojo) reemplaza al porcentaje de CPU; no aparece en Guachiman. Al pulsarlo se abre una confirmación con el nombre, la RAM y los pids: "¿Cerrar …?". Si confirmas:

- Una app (`.app`) se cierra como con Cmd-Q (`terminate()`); si no se encuentra la app en ejecución, se envía SIGTERM a sus procesos.
- Sesiones de Claude, huérfanos y procesos sueltos reciben SIGTERM en todo su árbol, hijos primero.
- A los 5 s, si algo sigue vivo, se pregunta "¿Forzar cierre?": `forceTerminate()` para apps y SIGKILL para el resto.

Nunca se señalan los pids 0 y 1 ni el propio Guachiman. El menú se construye al abrirlo, a partir del último sondeo, y no se reconstruye en cada sondeo.

## Menú

- **Cerrar huérfanos automáticamente** (apagado por defecto, se recuerda entre ejecuciones): si lo activas, un huérfano de más de 500 MB sostenido por 10 min recibe SIGTERM junto con sus descendientes, tras reverificar que sigue siendo huérfano. No se escala a SIGKILL y se te notifica qué se cerró.
- **Cerrar procesos que saturen el PC** (apagado por defecto, se recuerda entre ejecuciones, `autoKillSaturating`): si lo activas y la memoria libre del sistema baja de 20 %, un huérfano (ppid 1: node, vitest, next, playwright) de más de 500 MB genera la notificación "Guachiman cerrará X en 15 s". Si no pulsas "Cancelar cierre de X (pid N)" en el menú, recibe SIGTERM junto con sus descendientes, tras reverificar con un snapshot nuevo que la memoria libre siga bajo 20 % y que el huérfano siga existiendo y sobre 500 MB (si no, cancela y avisa "Cierre de X cancelado: …"). Pausar 1 h cancela un cierre ya programado. Solo huérfanos: nunca sesiones de Claude ni apps, para no perder trabajo.
- **Auto-compact de Claude** (submenú: "Por defecto de Claude", 50 %, 60 %, 70 %, 80 %; marca la opción activa): escribe `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (p. ej. `"70"`) en `~/.claude/settings.json`, el porcentaje de contexto al que Claude Code dispara el auto-compact. Solo cambia esa clave: edita el texto del archivo en su sitio, sin reordenar claves ni cambiar el formato (indentación, saltos de línea); si no existe la añade como primera entrada de `env` (o crea `env`, o el archivo), y "Por defecto" la borra y elimina `env` si queda vacío. Antes de escribir comprueba que el resultado es un JSON válido equivalente al original con ese único cambio; si no, no escribe nada y te avisa ("No se pudo editar ~/.claude/settings.json; cámbialo a mano"). La escritura es atómica (archivo temporal + rename). Claude Code lee los ajustes al arrancar, así que aplica a sesiones nuevas; para las ya abiertas ver "Contexto por sesión" abajo.
- **Pausar 1 h**: durante una hora no hay notificaciones ni cierres automáticos; el menú y el ícono siguen actualizándose. Mientras dura aparece "Reanudar (pausado hasta HH:mm)", que cancela la pausa.
- **Iniciar al encender**: crea o borra `~/Library/LaunchAgents/io.github.guachiman.plist` (surte efecto en el próximo inicio de sesión). "Salir" termina con estado 0, así que no se relanza.
- **Actualizar**: ejecuta `brew update` y `brew upgrade guachiman` y reinicia la app si hay una versión nueva; solo funciona con la instalación de Homebrew (equivale a `guachiman --update`).
  Guachiman busca versiones nuevas al arrancar y en los sondeos, como mucho una vez cada 6 h, y avisa con una notificación una sola vez por versión. Cuando hay una, el ítem pasa a "Actualizar a x.y.z" con un punto rojo. "Buscar actualizaciones" fuerza la consulta y avisa también si ya tienes la última o si no hay red. Sin Homebrew, el aviso de error ofrece "Abrir releases" (la página de versiones publicadas) para actualizar a mano. `guachiman --check-update` imprime la última versión publicada (el mayor tag `vX.Y.Z`; sale con 1 si falla la red). La consulta es una petición HTTPS anónima a la API pública de GitHub y no envía datos.
- **Desinstalar**: tras confirmar, borra la app, la instalación de Homebrew, la copia en `~/Applications`, los ajustes y los datos (equivale a `guachiman --uninstall`).
- Solo se ejecuta una instancia a la vez.

## Contexto por sesión (tokens usados)

Cada fila de sesión de Claude muestra "ctx 192k" junto al título: los tokens del último mensaje con `usage` de la transcripción (`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`), redondeados a miles ("ctx <1k" si son menos de 1 000). Guachiman no conoce la ventana de contexto del modelo (no hay ninguna fuente fiable en disco: la transcripción no declara la ventana ni `[1m]`), por eso no muestra porcentaje, ni colorea la cifra, ni genera alertas de contexto. Solo se lee la cola (256 KB) de la transcripción, al abrir el panel (y en `--once`, columna `CTX`, con la misma cadena), y se cachea por mtime: el sondeo no la toca. Sin dato no se muestra nada.

## Avisos a la sesión de Claude (interruptor "IA")

En la cabecera del panel, junto al engranaje, hay un botón **IA**. Está **apagado por defecto** (gris tenue) y se recuerda entre ejecuciones (`aiEnabled`). Solo funciona con Claude Code: si no está instalado, el botón queda deshabilitado ("Claude Code no está instalado").

- **Apagado**: Guachiman se comporta como sin IA. No escribe `alerts.jsonl` y no hay sesión de relay.
- **Encendido** (blanco): significa "permitido arrancar el relay". Cuando salta una alerta de sesión o de huérfano (y no estás en pausa), Guachiman arranca el relay si no estaba corriendo y añade una línea JSON a `~/Library/Application Support/Guachiman/alerts.jsonl`. El relay es una sesión de Claude Code en segundo plano (Haiku) que lee el archivo y avisa a la sesión dueña del proceso. Las alertas de apps y de memoria del sistema no lo arrancan ni escriben línea.
- Al encender (o al abrir la app con la IA encendida) Guachiman comprueba `claude auth status --json`, pero no arranca nada. Si Claude Code no tiene sesión iniciada, el relay no arrancará, el botón se pone amarillo y el panel muestra: "Inicia sesión en Claude Code: abre la terminal y ejecuta `claude`" (también llega una notificación). La comprobación se repite solo al abrir el panel; cuando pasa, el botón vuelve a blanco.
- El aviso del relay incluye pautas para partir tests y builds pesados (lotes, límite de workers y de heap) en vez de solo detenerlos.
- El relay se detiene solo tras 5 minutos seguidos sin sesión ni huérfano en alerta roja, al apagar el botón y al elegir "Salir" (o al recibir SIGTERM). Cada vez que se detiene (y al abrir la app) se vacía `alerts.jsonl`. Sin Guachiman no tiene sentido, así que ya no hay un LaunchAgent aparte.
- **Costo**: con la IA encendida y sin alertas no hay ningún proceso extra. Mientras el relay corre usa unos 386 MB de RAM (más el daemon de Claude Code) y gasta tokens de Haiku por alerta. Guachiman solo lanza procesos al arrancar el relay, al detenerlo, al comprobar la sesión y al salir; el sondeo no cambia.
- Requisito: el relay necesita un directorio confiable para Claude Code. Ver [relay/README.md](relay/README.md).

Campos de cada línea:

- Sesión: `kind` ("session"), `ts`, `pid` (raíz de Claude), `mb`, `limit_mb`, `cwd`, `title` (el título de la sesión si ya se conocía, si no `null`) y `top` (`pid`, `mb` y `cmd` del hijo más grande).
- Huérfano: `kind` ("orphan"), `ts`, `pid`, `name`, `mb`, `limit_mb` y `cwd`.

Antes de escribir, si el archivo pesa más de 1 MB se renombra a `alerts.jsonl.1` (sobrescribe el anterior). Guachiman no habla con Claude: solo deja el evento escrito.

La notificación de memoria libre baja nombra a los dos mayores consumidores entre sesiones y apps ("Memoria libre baja: 14 % · mayores: Brave Browser 4,2 GB, …").

Diseño eficiente: Guachiman no suma timers, hilos ni watchers; el hijo mayor y los consumidores salen de las lecturas que ya hace en cada sondeo, y el archivo se abre, se escribe y se cierra solo cuando una alerta se dispara.

## Qué no hace

Solo cierra lo que tú confirmas con el botón de detener de cada fila, o los huérfanos si activas "Cerrar huérfanos automáticamente" (apagado por defecto). Nunca cierra nada por su cuenta salvo esa opción, ni cierra sesiones de Claude sin tu confirmación.

## Compilar y correr

```sh
make          # compila build/Guachiman.app y la firma ad-hoc
make run      # compila y abre la app
make check    # ejecuta --once
make test     # ejecuta --selftest
make notify-test  # compila, abre la app y envía una notificación de prueba
make release VERSION=x.y.z  # publica una versión (ver "Publicar una versión")
make icon     # regenera icon/AppIcon.icns y los PNG de la barra desde icon/*.svg
make clean
```

Necesitas las herramientas de línea de comandos de Xcode (`swiftc`).

## Verificación: `--once`

```sh
build/Guachiman.app/Contents/MacOS/Guachiman --once
```

Imprime una tabla con pid, etiqueta, MB totales, estado (verde, amarillo o rojo; el gris no se puede saber con una sola muestra) y cwd de cada sesión, los huérfanos, las 10 apps que más RAM usan (con su CPU medida en ~1 s), la memoria libre y los umbrales calculados, y termina sin abrir la interfaz. Sirve como `doctor`.

## Umbrales

Se calculan a partir de la RAM física (`hw.memsize`). Las constantes están al inicio de `guachiman.swift`.

- Sesión: más del 15% de la RAM física, sostenido por al menos 60 s.
- App: solo CPU, más de 80% de un núcleo sostenido por 120 s; se avisa una vez por episodio (otro aviso solo si la CPU baja del umbral y vuelve a subir). La RAM de las apps no avisa por separado: sale en el aviso de memoria libre baja.
- Sistema: memoria libre menor a 20% (`kern.memorystatus_level`).
- Enfriamiento de 10 min por alerta (sesiones, huérfanos y sistema); avisa antes solo si el valor creció más de 25% desde el último aviso.
- Sondeo cada 20 s.

El ícono se atenúa sin sesiones y se pone rojo mientras haya una alerta activa.

## Instalación con Homebrew

Requisitos: macOS 13 o superior, [Homebrew](https://brew.sh) y las Command Line Tools (`xcode-select --install`; se compila desde el código fuente, no hace falta Xcode completo).

1. Confía en el tap (desde Homebrew 7 los taps de terceros lo requieren antes de instalar):

   ```sh
   brew trust xklbr/tap
   ```

2. Instala:

   ```sh
   brew install xklbr/tap/guachiman
   ```

3. Inícialo ahora y en cada inicio de sesión:

   ```sh
   brew services start guachiman
   ```

   La primera vez macOS pide permiso para mostrar notificaciones: acéptalo (si lo rechazaste, usa "Activar notificaciones" en el engranaje del panel). Con `brew services` no actives también "Iniciar al encender".

4. Solo si vas a usar el botón IA: necesitas Claude Code instalado e iniciado sesión, y el directorio del relay debe confiarse una vez:

   ```sh
   mkdir -p ~/Library/Application\ Support/Guachiman/relay-cwd
   cd ~/Library/Application\ Support/Guachiman/relay-cwd && claude
   ```

   Acepta el aviso de confianza, sal con `/exit` y luego enciende IA en el panel. Detalles en [relay/README.md](relay/README.md).

La app se copia a `~/Applications` la primera vez que corre, para que aparezca en Spotlight y Launchpad; si la abres desde ahí mientras el servicio está activo, se muestra el panel.

Para detenerlo usa `brew services stop guachiman`.

Para desinstalar todo, ejecuta `guachiman --uninstall` o elige Ajustes (engranaje) > "Desinstalar". Se quitan la app, la instalación de Homebrew, la copia en `~/Applications`, el inicio automático, los ajustes y los datos. El tap se conserva; si también quieres quitarlo, usa `brew untap xklbr/tap`. El permiso de notificaciones se quita en Ajustes del Sistema > Notificaciones.

Desde la terminal puedes ejecutar `guachiman --once` para ver un diagnóstico.

Para actualizar a la última versión:

```sh
brew update && brew upgrade guachiman
```

O bien `guachiman --update`, o Ajustes (engranaje) > "Actualizar". Al reiniciar con la nueva versión recibes una notificación "Guachiman actualizado a x.y.z".

Si tenías abierta una copia desde `build/`, ciérrala antes: la app es de instancia única y la segunda no arranca.

## Publicar una versión

Para quien mantiene el proyecto. No hay cuenta ni registro en Homebrew: el tap es simplemente el repositorio público [xklbr/homebrew-tap](https://github.com/xklbr/homebrew-tap), cuya fórmula `Formula/guachiman.rb` apunta al tarball del tag `vX.Y.Z` de este repo y a su `sha256`.

Requisitos:

- Permiso de `git push` (y `gh` autenticado, si lo usas) en `xklbr/guachiman` y `xklbr/homebrew-tap`.
- El tap clonado como carpeta hermana: `../homebrew-tap` (o define `TAP_DIR`).
- Command Line Tools.
- Ambos repos limpios, en `main` y al día con `origin`.

Primero ensaya y luego publica:

```sh
DRY_RUN=1 make release VERSION=x.y.z   # valida e imprime los comandos, sin cambiar nada
make release VERSION=x.y.z
```

`scripts/release.sh` hace, en orden:

1. Valida la versión (`x.y.z`), que el tag no exista (local ni en origin), que ambos repos estén limpios, en `main` y al día.
2. Pone `CFBundleShortVersionString` en la versión y suma 1 a `CFBundleVersion` en `Info.plist`.
3. Ejecuta `make test`.
4. Hace commit `chore: versión x.y.z`, crea el tag anotado `vx.y.z` y sube `main` y el tag.
5. Descarga el tarball del tag (con reintentos) y calcula su `sha256`.
6. Actualiza `url` y `sha256` de la fórmula, hace commit `feat: guachiman x.y.z` en el tap y lo sube.

### A mano

Si el script falla a medias o prefieres hacerlo manualmente:

```sh
# En guachiman: edita Info.plist (versión y CFBundleVersion), luego
make test
git commit -am "chore: versión x.y.z"
git tag -a vx.y.z -m "Guachiman x.y.z"
git push origin main vx.y.z

# Calcula el sha256 del tarball
curl -fsSL https://github.com/xklbr/guachiman/archive/refs/tags/vx.y.z.tar.gz | shasum -a 256

# En homebrew-tap: actualiza url y sha256 en Formula/guachiman.rb
git commit -am "feat: guachiman x.y.z"
git push origin main
```

### Verificar

```sh
brew update
brew upgrade guachiman
brew test xklbr/tap/guachiman
brew audit --strict --formula xklbr/tap/guachiman
```

### ¿Y homebrew-core o homebrew-cask?

- **homebrew-core** exige que el proyecto sea notable (alrededor de 75 estrellas, o 30 forks/watchers) y no acepta apps con interfaz gráfica.
- **homebrew-cask** exige firma de Apple y notarización (Apple Developer Program, USD 99 al año).

Por eso se eligió el tap propio.

## Licencia

MIT.
