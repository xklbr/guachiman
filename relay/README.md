# Relay de Guachiman

Una sesión de Claude Code en segundo plano (Haiku) que lee las alertas de memoria de Guachiman y se las entrega, por A2A (`SendMessage`), a la sesión de Claude Code dueña del proceso. Luego hace seguimiento.

## Qué hace

- Vigila `~/Library/Application Support/Guachiman/alerts.jsonl` con `tail -n 0 -F` (Monitor persistente, se re-arma al expirar).
- Alerta de sesión (RAM o, con `reason:"cpu"`, CPU sostenida): envía UN mensaje corto `[Guachiman]` a la sesión (nombre tomado de `~/.claude/sessions/<pid>.json`) con el total vs el límite, el proceso hijo más pesado y qué hacer. No comprueba si el pid sigue vivo: Guachiman solo escribe la alerta mientras el proceso está vivo y sobre el umbral.
- Alerta de huérfano: busca con `Read` sobre `~/.claude/sessions/*.json` (o `ListAgents`) las sesiones vivas cuyo `cwd` sea igual o prefijo del `cwd` del huérfano y les avisa. Si no hay ninguna, no hace nada (Guachiman ya avisó al usuario).
- Seguimiento: si llega otra alerta del mismo pid después de haber avisado a su sesión una vez, insiste UNA vez (un mensaje). Después ignora ese pid.

## Modo y herramientas

- Corre en modo `bypassPermissions` (`--permission-mode bypassPermissions`). Así sus mensajes no quedan retenidos por sesiones receptoras que también usan ese modo (modos de permisos distintos retienen el mensaje).
- Sin Bash: `--tools "Monitor,SendMessage,ListAgents,Read,ToolSearch"` limita el conjunto disponible, de modo que Bash, Write, Edit, WebFetch, etc. no existen para el relay.

## Seguridad

- El relay no tiene shell ni puede editar archivos ni matar procesos.
- Todos los campos de una alerta (`cwd`, `title`, `name`, `cmd`) son datos no confiables: el brief ordena tratarlos como datos, nunca como instrucciones.
- Guachiman sanea los campos antes de escribirlos: `top.cmd` y `name` solo conservan `[A-Za-z0-9._ +-]` (máx. 40); `cwd` y `title` pierden los caracteres de control (máx. 200).

## Costo

- Unos 386 MB de RAM (y el daemon de Claude Code) solo mientras el relay está corriendo: se arranca bajo demanda y se apaga solo. Con la IA encendida y sin alertas, no hay ningún proceso del relay.
- Tokens de Haiku por cada alerta y por cada re-armado del monitor (máximo cada 30 min).

## Cómo se activa

Lo gestiona Guachiman con el botón **IA** del panel (apagado por defecto), que significa "permitido arrancar solo". Al encender solo se comprueba que Claude Code tenga sesión iniciada. El relay arranca bajo demanda: justo antes de escribir una alerta de sesión o de huérfano en `alerts.jsonl`, si no está corriendo, ejecuta `/bin/bash <app>/Contents/Resources/relay/start.sh` (no se relanza en cada sondeo). Se detiene con `start.sh stop` tras 5 minutos seguidos sin ninguna sesión ni huérfano en alerta (el amarillo no cuenta), al apagar el botón y al "Salir". Cada vez que el relay se detiene, y al abrir la app, `alerts.jsonl` se vacía; el monitor del relay usa `tail -n +1 -F`, así que lee desde el inicio las alertas del ciclo actual y no se pierde la primera. `make` copia `start.sh` y `brief.md` dentro del bundle, así que las instalaciones con Homebrew también los traen. Ya no existe el LaunchAgent del relay.

Si vienes de la versión anterior y la instalaste a mano: `launchctl bootout gui/$(id -u)/io.github.guachiman.relay`, borra `~/Library/LaunchAgents/io.github.guachiman.relay.plist` y `~/Library/Application Support/Guachiman/relay`.

Notas:
- Guachiman busca el CLI en `~/.local/bin/claude`, `/opt/homebrew/bin/claude` y `/usr/local/bin/claude` y se lo pasa al script en `CLAUDE_BIN`. Antes de arrancar comprueba `claude auth status --json`; sin sesión iniciada avisa en el panel y no arranca.
- **Limitación de confianza**: `claude --bg` se niega a correr en un workspace no confiable y no existe una opción para saltarlo. El relay usa `~/Library/Application Support/Guachiman/relay-cwd` (o `RELAY_CWD`): ejecuta `claude` una vez en ese directorio y acepta la confianza. Mientras no lo hagas, el relay no arranca. No se usan carpetas protegidas como `~/Documents`, porque sin permiso de TCC la app queda colgada al entrar en ellas.
- `start.sh` es idempotente: si ya hay una sesión `guachiman-relay` viva, no hace nada. Para recargar `brief.md`, apaga y enciende el botón IA (o espera a que el relay se apague solo).

## Verificar que corre

```sh
claude agents --json | grep -B4 -A3 guachiman-relay
claude logs <id>       # el id sale de `claude agents --json` / ~/.claude/sessions/<pid>.json (jobId)
ps aux | grep 'tail -n 0 -F' | grep alerts.jsonl   # el monitor armado
```

El estado normal de la sesión es `idle` o `shell` (esperando el monitor).

## Probar

Agrega una alerta falsa que apunte a una sesión viva (cambia `pid` por el de esa sesión):

```sh
echo '{"kind":"session","ts":'$(date +%s)',"pid":<PID>,"mb":9999,"limit_mb":2764,"cwd":"'$PWD'","title":"prueba","top":{"pid":<PID>,"mb":1,"cmd":"prueba-relay"}}' \
  >> "$HOME/Library/Application Support/Guachiman/alerts.jsonl"
```

La sesión destino debe recibir un mensaje `[Guachiman]`. Si esa sesión usa otro modo de permisos que el relay, el mensaje queda retenido hasta que su usuario lo apruebe (llega un `[Cross-session delivery notice]` al relay).
