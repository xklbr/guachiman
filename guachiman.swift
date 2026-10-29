// Guachiman — menu bar app que vigila la RAM y la CPU de todas las apps, además de
// las sesiones de Claude Code y los procesos huérfanos.
// Solo cierra procesos cuando el usuario lo confirma con el botón de detener de cada fila
// del panel, o con SIGTERM a huérfanos (ppid 1: node, vitest, next, playwright) si activa
// "Cerrar huérfanos automáticamente" (apagado de fábrica). "Cerrar procesos que saturen el PC"
// (también apagado) avisa 15 s antes de cerrar un huérfano grande cuando la memoria libre baja de 20 %.

import AppKit
import Darwin
import UserNotifications

// MARK: - Constantes

enum Config {
    static let sessionFraction = 0.15            // alerta de sesión: > 15% de la RAM física
    static let sessionSustained: TimeInterval = 60   // ... sostenido al menos 60 s
    static let systemFreeMinPercent = 20         // alerta de sistema: libre < 20%
    static let cooldown: TimeInterval = 600      // enfriamiento por clave: 10 min
    static let regrowthFactor = 1.25             // re-alerta antes si el valor creció > 25%
    static let pollActive: TimeInterval = 20     // intervalo de sondeo
    static let appCpuPercent = 80.0              // alerta de app: > 80% de un núcleo
    static let appCpuSustained: TimeInterval = 120   // ... sostenido 120 s
    static let sessionExecutable = "claude"
    static let orphanBytes: UInt64 = 500 * 1_048_576  // huérfano: > 500 MB
    static let orphanAlertAfter: TimeInterval = 60    // ... sostenido 60 s para avisar
    static let orphanCloseAfter: TimeInterval = 600   // ... sostenido 10 min para cerrar
    static let idleCpuPercent = 1.0              // fila inactiva: CPU < 1 %
    static let idleAfter: TimeInterval = 120     // ... de forma continua por 120 s
    static let warnFraction = 0.75               // amarillo: >= 75 % de un umbral
    static let pauseDuration: TimeInterval = 3600
    static let updateCheckInterval: TimeInterval = 6 * 3600
    static let tagsURL = "https://api.github.com/repos/xklbr/guachiman/tags?per_page=20"
    static let releasesPageURL = "https://github.com/xklbr/guachiman/releases"
    static let lastUpdateCheckKey = "lastUpdateCheck"
    static let notifiedVersionKey = "notifiedVersion"
    static let autoCloseKey = "autoCloseOrphans"
    static let autoKillSaturatingKey = "autoKillSaturating"
    static let saturatingKillDelay: TimeInterval = 15   // aviso antes de cerrar un huérfano que satura
    static let aiKey = "aiEnabled"
    static let relayIdleStop: TimeInterval = 300   // relay apagado tras 5 min seguidos sin alerta activa
    static let loginText = "Inicia sesión en Claude Code: abre la terminal y ejecuta `claude`"
    static let agentLabel = "io.github.guachiman"
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Guachiman").path
    static let alertsFile = supportDir + "/alerts.jsonl"
}

// MARK: - Lógica pura (cubierta por --selftest)

enum Orphan {
    static let names: Set<String> = ["node", "vitest", "next", "playwright"]

    /// Nombre coincidente: último componente del ejecutable o del primer token de argv[0];
    /// acepta sufijo con guion (`next-server`) porque las herramientas renombran el título.
    static func name(exe: String?, argv0: String?) -> String? {
        for c in [exe, argv0?.split(separator: " ").first.map(String.init)] {
            guard let c else { continue }
            let n = (c as NSString).lastPathComponent.lowercased()
            if names.contains(n) || names.contains(where: { n.hasPrefix($0 + "-") }) { return n }
        }
        return nil
    }
}

/// Desde cuándo está cada clave (pid, grupo de app...) por encima del umbral.
struct SustainedTracker<Key: Hashable> {
    private var since: [Key: Date] = [:]

    /// Devuelve cuánto lleva sostenido (0 si no está por encima).
    mutating func update(_ key: Key, over: Bool, now: Date) -> TimeInterval {
        guard over else { since[key] = nil; return 0 }
        let start = since[key] ?? now
        since[key] = start
        return now.timeIntervalSince(start)
    }

    mutating func retain(_ live: Set<Key>) { since = since.filter { live.contains($0.key) } }
}

/// Grupo de una app: el `.app` más externo del path; sin `.app`, el proceso es su propio grupo (clave con pid).
func appGroup(path: String?, argv0: String?, pid: pid_t) -> (key: String, name: String) {
    if let path, let r = path.range(of: ".app/") {
        return (String(path[..<r.upperBound]), ((String(path[..<r.lowerBound])) as NSString).lastPathComponent)
    }
    return ("pid:\(pid)", ((path ?? argv0 ?? "?") as NSString).lastPathComponent)
}

/// % de un núcleo a partir de dos lecturas de tiempo de CPU en unidades Mach.
func cpuPercent(prev: UInt64, cur: UInt64, wall: TimeInterval, timebase: (numer: UInt32, denom: UInt32)) -> Double {
    guard wall > 0, cur >= prev, timebase.denom > 0 else { return 0 }
    return Double(cur - prev) * Double(timebase.numer) / Double(timebase.denom) / (wall * 1e9) * 100
}

enum RowColor: String {
    case green = "verde", yellow = "amarillo", red = "rojo", gray = "gris"
}

/// Color de una fila. Gris (inactiva) manda sobre el resto; después rojo (sobre el umbral),
/// amarillo (>= 75 % de algún umbral) y verde. `cpuLimit` nil = sin umbral de CPU (huérfanos).
func rowColor(bytes: UInt64, cpu: Double, ramLimit: UInt64, cpuLimit: Double?, idleFor: TimeInterval) -> RowColor {
    if cpu < Config.idleCpuPercent, idleFor >= Config.idleAfter { return .gray }
    if bytes > ramLimit || (cpuLimit.map { cpu > $0 } ?? false) { return .red }
    if Double(bytes) >= Config.warnFraction * Double(ramLimit)
        || (cpuLimit.map { cpu >= Config.warnFraction * $0 } ?? false) { return .yellow }
    return .green
}

/// Color del anillo de memoria libre con la misma regla que las filas: rojo bajo el mínimo,
/// amarillo si lo usado llega al 75 % del umbral de uso, verde en otro caso.
func freeMemoryColor(freePercent: Int) -> RowColor {
    let usedLimit = Double(100 - Config.systemFreeMinPercent)
    if freePercent < Config.systemFreeMinPercent { return .red }
    if Double(100 - freePercent) >= Config.warnFraction * usedLimit { return .yellow }
    return .green
}

/// % de CPU total de la máquina entre dos lecturas de ticks (ocupado / total).
func cpuLoadPercent(prev: (busy: UInt64, total: UInt64), cur: (busy: UInt64, total: UInt64)) -> Double {
    guard cur.total > prev.total, cur.busy >= prev.busy else { return 0 }
    return min(100, Double(cur.busy - prev.busy) / Double(cur.total - prev.total) * 100)
}

private let hostPort = mach_host_self()

/// Una sola llamada a host_statistics: ticks ocupados (user+system+nice) y totales.
func cpuTicks() -> (busy: UInt64, total: UInt64)? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return nil }
    let t = info.cpu_ticks
    let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
    return (busy, busy + UInt64(t.2))
}

func pauseActive(until: Date?, now: Date) -> Bool {
    guard let until else { return false }
    return now < until
}

/// Componentes numéricos de "v0.7.0", "0.7.0" o "0.7"; nil ante basura o sufijos (p. ej. "-beta").
func parseVersion(_ s: String) -> [Int]? {
    let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count) else { return nil }
    var out: [Int] = []
    for p in parts {
        guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(p) else { return nil }
        out.append(n)
    }
    return out
}

func isNewerVersion(_ a: String, than b: String) -> Bool {
    guard var x = parseVersion(a), var y = parseVersion(b) else { return false }
    let n = max(x.count, y.count)
    x += Array(repeating: 0, count: n - x.count)
    y += Array(repeating: 0, count: n - y.count)
    return x.lexicographicallyPrecedes(y) ? false : x != y
}

/// Mayor versión entre los `name` de los tags que pasan `parseVersion` (sin "v"); no asume orden.
func latestVersion(fromTagsJSON data: Data) -> String? {
    guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    var best: String?
    for tag in arr {
        guard let name = tag["name"] as? String, parseVersion(name) != nil else { continue }
        let v = name.hasPrefix("v") ? String(name.dropFirst()) : name
        if best == nil || isNewerVersion(v, than: best!) { best = v }
    }
    return best
}

func shouldCheckForUpdate(last: Date?, now: Date) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= Config.updateCheckInterval || last > now
}

var installedVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

/// Consulta anónima a la API pública de GitHub; nil ante cualquier fallo. El callback corre en otra cola.
func fetchLatestVersion(completion: @escaping (String?) -> Void) {
    guard let url = URL(string: Config.tagsURL) else { return completion(nil) }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Guachiman/\(installedVersion)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return completion(nil) }
        completion(latestVersion(fromTagsJSON: data))
    }.resume()
}

/// Cierre automático solo si la memoria sigue baja y el huérfano (nil = desapareció) sigue sobre el umbral.
func shouldProceedSaturatingKill(freePercent: Int, orphanBytes: UInt64?) -> Bool {
    freePercent < Config.systemFreeMinPercent && (orphanBytes ?? 0) > Config.orphanBytes
}

func launchAgentPlist(executable: String) -> [String: Any] {
    ["Label": Config.agentLabel,
     "ProgramArguments": [executable],
     "RunAtLoad": true,
     "KeepAlive": ["SuccessfulExit": false],
     "ProcessType": "Interactive"]
}

/// Hijo más grande (por RSS) de una sesión; el pid raíz nunca cuenta.
struct TopChild: Equatable {
    var pid: pid_t
    var bytes: UInt64
    var cmd = ""
}

func largerChild(_ cur: TopChild?, pid: pid_t, bytes: UInt64, root: pid_t) -> TopChild? {
    guard pid != root, bytes > (cur?.bytes ?? 0) else { return cur }
    return TopChild(pid: pid, bytes: bytes)
}

/// Nombre corto del comando: último componente de argv[0], o del ejecutable; máx. 80.
func commandName(argv0: String?, exe: String?) -> String {
    for c in [argv0, exe] {
        guard let c, !c.isEmpty else { continue }
        let n = (c as NSString).lastPathComponent
        if !n.isEmpty { return String(n.prefix(80)) }
    }
    return "?"
}

func jsonLine(_ d: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Saneo de campos no confiables antes de escribirlos en `alerts.jsonl`: nombres solo [A-Za-z0-9._ +-], máx. 40.
func sanitizeName(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter {
        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._ +-".unicodeScalars.contains($0))
    }).prefix(40))
}

/// Rutas y títulos: sin caracteres de control, máx. 200.
func sanitizeText(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(200))
}

/// Línea de `alerts.jsonl` para una sesión que superó el umbral.
func sessionAlertLine(ts: Int, pid: pid_t, mb: UInt64, limitMB: UInt64, cwd: String, title: String?, top: TopChild?) -> String {
    var d: [String: Any] = ["kind": "session", "ts": ts, "pid": Int(pid), "mb": mb, "limit_mb": limitMB,
                            "cwd": sanitizeText(cwd), "title": title.map { sanitizeText($0) } ?? NSNull()]
    d["top"] = top.map { ["pid": Int($0.pid), "mb": $0.bytes / 1_048_576, "cmd": sanitizeName($0.cmd)] as [String: Any] } ?? NSNull()
    return jsonLine(d)
}

/// Línea de `alerts.jsonl` para un huérfano.
func orphanAlertLine(ts: Int, pid: pid_t, name: String, mb: UInt64, limitMB: UInt64, cwd: String) -> String {
    jsonLine(["kind": "orphan", "ts": ts, "pid": Int(pid), "name": sanitizeName(name), "mb": mb, "limit_mb": limitMB, "cwd": sanitizeText(cwd)])
}

/// Añade una línea al archivo de eventos; rota a `.1` si pasa de 1 MB (un solo stat), crea el directorio al vuelo,
/// cierra al instante, ignora errores.
func appendAlert(_ line: String, path: String = Config.alertsFile, maxBytes: Int = 1_048_576) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    var st = stat()
    if stat(path, &st) == 0, Int(st.st_size) > maxBytes { rename(path, path + ".1") }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    let bytes = Array((line + "\n").utf8)
    _ = write(fd, bytes, bytes.count)
    close(fd)
}

// MARK: - Relay de IA (sesión de Claude Code en segundo plano; solo se lanzan procesos al activar, arrancar o salir)

/// Ruta del CLI de Claude Code (launchd trae un PATH mínimo, así que se buscan las ubicaciones habituales).
func claudeBinary() -> String? {
    let home = NSHomeDirectory()
    return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Interpreta la salida de `claude auth status --json`: true solo si `loggedIn` es true.
func parseAuthLoggedIn(_ data: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["loggedIn"] as? Bool ?? false
}

/// `claude auth status --json` (~0.2 s). Error, salida no válida o código distinto de 0 cuentan como "sin sesión".
func claudeLoggedIn(_ claude: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = ["auth", "status", "--json"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 && parseAuthLoggedIn(data)
}

// MARK: - Uso de Claude (límites del plan; solo lectura, sin refrescar jamás el token de Claude Code)

struct UsageLimit: Equatable {
    let label: String
    let percent: Int
    let severity: String
    let resetsAt: Date?
}

/// Token OAuth desde el JSON del llavero (`claudeAiOauth`); nil si falta o ya venció (`expiresAt` en ms).
func parseOAuthToken(_ data: Data, now: Date) -> String? {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let c = o["claudeAiOauth"] as? [String: Any],
          let token = c["accessToken"] as? String, !token.isEmpty else { return nil }
    if let exp = (c["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 <= now.timeIntervalSince1970 { return nil }
    return token
}

/// Interpreta `/api/oauth/usage`: nil si el formato no es el esperado; ignora los límites desconocidos o incompletos.
func parseUsageLimits(_ data: Data) -> [UsageLimit]? {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let arr = o["limits"] as? [[String: Any]] else { return nil }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    return arr.compactMap { l in
        guard let kind = l["kind"] as? String, let pct = (l["percent"] as? NSNumber)?.intValue else { return nil }
        let label: String
        switch kind {
        case "session": label = "Sesión (5 h)"
        case "weekly_all": label = "Semanal"
        case "weekly_scoped":
            let name = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            label = "Semanal · " + (name ?? "modelo")
        default: return nil
        }
        let reset = (l["resets_at"] as? String).flatMap { frac.date(from: $0) ?? plain.date(from: $0) }
        return UsageLimit(label: label, percent: max(0, pct), severity: l["severity"] as? String ?? "normal", resetsAt: reset)
    }
}

/// "HH:mm" si el reinicio es hoy; si no, día corto + hora ("mié 14:30").
func usageResetText(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "es")
    f.timeZone = calendar.timeZone
    f.dateFormat = calendar.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
    // Redondeo al minuto: la API a veces devuelve 22:59:59.x en vez de 23:00.
    let m = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    return f.string(from: m).replacingOccurrences(of: ".", with: "")
}

/// Pide los límites sin bloquear el hilo principal; `done` se llama en main con nil si no hay datos.
func fetchClaudeUsage(done: @escaping ([UsageLimit]?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return DispatchQueue.main.async { done(nil) } }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let token = parseOAuthToken(out, now: Date()) else {
            return DispatchQueue.main.async { done(nil) }
        }
        // curl con la config por stdin: el token nunca aparece en argv (visible con `ps`).
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        c.arguments = ["-sS", "-m", "10", "-K", "-", "-w", "\n%{http_code}", "https://api.anthropic.com/api/oauth/usage"]
        let inPipe = Pipe(), outPipe = Pipe()
        c.standardInput = inPipe
        c.standardOutput = outPipe
        c.standardError = FileHandle.nullDevice
        guard (try? c.run()) != nil else { return DispatchQueue.main.async { done(nil) } }
        inPipe.fileHandleForWriting.write(Data("header = \"Authorization: Bearer \(token)\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\n".utf8))
        inPipe.fileHandleForWriting.closeFile()
        let body = outPipe.fileHandleForReading.readDataToEndOfFile()
        c.waitUntilExit()
        var limits: [UsageLimit]?
        if c.terminationStatus == 0, let nl = body.lastIndex(of: 10),
           String(decoding: body[body.index(after: nl)...], as: UTF8.self) == "200" {
            limits = parseUsageLimits(body[..<nl])
        }
        DispatchQueue.main.async { done(limits) }
    }
}

/// El relay corriendo se apaga cuando no hay condición de alerta (roja) de forma continua durante `Config.relayIdleStop`.
func relayShouldStop(running: Bool, quietSince: Date?, now: Date) -> Bool {
    running && quietSince.map { now.timeIntervalSince($0) >= Config.relayIdleStop } ?? false
}

/// Vacía `alerts.jsonl`: el relay lee el archivo desde el inicio (`tail -n +1`), así que no debe quedar nada de un ciclo anterior.
func truncateAlerts(path: String = Config.alertsFile) {
    guard FileManager.default.fileExists(atPath: path) else { return }
    try? Data().write(to: URL(fileURLWithPath: path))
}

/// Ejecuta `start.sh [arg]` del bundle; con `wait` espera a que termine (para detener al salir).
func runRelay(_ arg: String?, wait: Bool) {
    guard let claude = claudeBinary(),
          let script = Bundle.main.resourcePath.map({ $0 + "/relay/start.sh" }),
          FileManager.default.fileExists(atPath: script) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + (arg.map { [$0] } ?? [])
    // Entorno mínimo: si Guachiman se lanzó desde una sesión de Claude Code heredaría su entorno y el relay no arrancaría limpio.
    let home = NSHomeDirectory()
    let env: [String: String] = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
               "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "CLAUDE_BIN": claude]
        .merging(ProcessInfo.processInfo.environment["RELAY_CWD"].map { ["RELAY_CWD": $0] } ?? [:]) { a, _ in a }
    p.environment = env
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return }
    if wait { p.waitUntilExit() }
}

/// Texto de memoria libre baja con los 2 mayores consumidores (sesiones y apps) por RAM.
func systemLowText(freePercent: Int, consumers: [(name: String, bytes: UInt64)]) -> String {
    var t = "Memoria libre baja: \(freePercent) %"
    let top = consumers.sorted { $0.bytes > $1.bytes }.prefix(2)
    if !top.isEmpty { t += " · mayores: " + top.map { "\($0.name) \(formatBytes($0.bytes))" }.joined(separator: ", ") }
    return t
}

// MARK: - Título de sesión de Claude Code

/// Directorio codificado de proyectos de Claude: cada carácter no alfanumérico del cwd pasa a "-".
func encodedProjectDir(_ cwd: String) -> String {
    String(cwd.unicodeScalars.map { s -> Character in
        (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
    })
}

/// Últimos `customTitle` y `aiTitle` de un trozo de JSONL.
func lastTitles(in text: String) -> (custom: String?, ai: String?) {
    var custom: String?, ai: String?
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        let isC = custom == nil && line.contains("\"custom-title\"")
        let isA = ai == nil && line.contains("\"ai-title\"")
        guard isC || isA,
              let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if isC, o["type"] as? String == "custom-title", let t = o["customTitle"] as? String, !t.isEmpty { custom = t }
        if isA, o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String, !t.isEmpty { ai = t }
        if custom != nil { break }   // el renombrado manual manda; no hace falta seguir
    }
    return (custom, ai)
}

/// Título de una sesión desde un trozo de JSONL: el último `custom-title` gana sobre el último `ai-title`.
func extractSessionTitle(_ text: String) -> String? {
    let t = lastTitles(in: text)
    return t.custom ?? t.ai
}

func truncatedTitle(_ s: String) -> String { s.count > 50 ? String(s.prefix(49)) + "…" : s }

private struct TitleEntry { var title: String?; var mtime: Date; var checkedAt: Date }
private var titleCache: [pid_t: TitleEntry] = [:]
private var transcriptPathCache: [String: String?] = [:]
private let claudeDir = NSHomeDirectory() + "/.claude"

private func transcriptPath(sessionId: String, cwd: String) -> String? {
    let direct = "\(claudeDir)/projects/\(encodedProjectDir(cwd))/\(sessionId).jsonl"
    if FileManager.default.fileExists(atPath: direct) { return direct }
    if let c = transcriptPathCache[sessionId] { return c }
    let base = "\(claudeDir)/projects"
    var found: String?
    for d in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
        let p = "\(base)/\(d)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: p) { found = p; break }
    }
    transcriptPathCache[sessionId] = found
    return found
}

/// Lee todo el archivo en trozos de 1 MB (sin cargarlo entero), conservando el último título de cada tipo.
private func scanWholeFile(_ fh: FileHandle) -> String? {
    var custom: String?, ai: String?
    var carry = Data()
    try? fh.seek(toOffset: 0)
    while true {
        let chunk = (try? fh.read(upToCount: 1 << 20)) ?? Data()
        let eof = chunk.isEmpty
        var buf = carry + chunk
        carry = Data()
        if !eof, let nl = buf.lastIndex(of: 0x0A) {
            carry = buf.suffix(from: nl + 1)
            buf = buf.prefix(through: nl)
        } else if !eof { carry = buf; continue }
        let t = lastTitles(in: String(decoding: buf, as: UTF8.self))
        if let c = t.custom { custom = c }
        if let a = t.ai { ai = a }
        if eof { break }
    }
    return custom ?? ai
}

/// Título de la sesión (lo que muestra la pestaña de la terminal), con caché en memoria. Solo se llama
/// cuando hace falta una etiqueta; refresca a lo sumo cada 5 min y solo si cambió el mtime de la transcripción.
func sessionTitle(pid: pid_t) -> String? {
    let now = Date()
    let old = titleCache[pid]
    if let old, now.timeIntervalSince(old.checkedAt) < 300 { return old.title }
    var entry = TitleEntry(title: nil, mtime: .distantPast, checkedAt: now)
    defer { titleCache[pid] = entry }
    guard let data = FileManager.default.contents(atPath: "\(claudeDir)/sessions/\(pid).json"),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String,
          let path = transcriptPath(sessionId: sid, cwd: cwd),
          let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    else { return nil }
    entry.mtime = mtime
    if let old, old.mtime == mtime { entry.title = old.title; return old.title }
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let tail: UInt64 = 256 * 1024
    try? fh.seek(toOffset: size > tail ? size - tail : 0)
    let text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
    var title = extractSessionTitle(text)
    if title == nil { title = old != nil ? old?.title : (size > tail ? scanWholeFile(fh) : nil) }
    entry.title = title
    return title
}

/// Título ya conocido, sin leer disco.
func cachedSessionTitle(pid: pid_t) -> String? { titleCache[pid]?.title }

func pruneTitleCache(live: Set<pid_t>) {
    titleCache = titleCache.filter { live.contains($0.key) }
    ctxCache = ctxCache.filter { live.contains($0.key) }
}

/// Etiqueta visible: título de Claude Code (máx. 50) o, sin él, la carpeta.
func sessionLabel(_ s: Session) -> String { sessionTitle(pid: s.pid).map(truncatedTitle) ?? s.label }

/// "ctx 192k": tokens usados redondeados a miles; menos de 1 000 → "ctx <1k".
func formatContextTokens(_ used: Int) -> String {
    used < 1000 ? "ctx <1k" : "ctx \((used + 500) / 1000)k"
}

/// Último mensaje con `message.usage` (no vacío) del texto de una transcripción; ignora líneas rotas.
func parseContextUsage(_ text: String) -> Int? {
    for line in text.split(separator: "\n").reversed() where line.contains("\"usage\"") {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let used = n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
        if used > 0 { return used }
    }
    return nil
}

let autoCompactEnvKey = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"

/// Porcentaje de auto-compact guardado en `env` de settings.json (nil = por defecto de Claude).
func autoCompactPct(_ root: [String: Any]) -> Int? {
    let v = (root["env"] as? [String: Any])?[autoCompactEnvKey]
    return (v as? String).flatMap { Int($0) } ?? (v as? NSNumber)?.intValue
}

/// Copia de settings con solo `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` cambiado; nil lo elimina (y `env` si queda vacío).
func applyAutoCompact(_ root: [String: Any], pct: Int?) -> [String: Any] {
    var r = root
    var env = (r["env"] as? [String: Any]) ?? [:]
    if let pct { env[autoCompactEnvKey] = String(pct) } else { env[autoCompactEnvKey] = nil }
    r["env"] = env.isEmpty ? nil : env
    return r
}

/// Edición textual mínima de `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` en el texto de settings.json (conserva orden y formato).
/// nil = no se pudo editar con seguridad. Texto vacío = archivo inexistente.
func editAutoCompact(text: String, pct: Int?) -> String? {
    let b = Array(text.utf8)
    let keyBytes = Array(autoCompactEnvKey.utf8)
    let valueBytes = Array("\"\(pct ?? 0)\"".utf8)
    let entry = Array("\"\(autoCompactEnvKey)\": ".utf8) + valueBytes
    let envEntry = Array("\"env\": {".utf8) + entry + Array("}".utf8)
    func splice(_ r: Range<Int>, _ ins: [UInt8]) -> String? {
        String(bytes: Array(b[..<r.lowerBound]) + ins + Array(b[r.upperBound...]), encoding: .utf8)
    }
    func insertFirst(_ o: JSONObjectSpan, _ item: [UInt8]) -> String? {
        guard let first = o.members.first else { return splice((o.open + 1)..<o.close, item) }
        var sep = Array(", ".utf8)
        if let nl = b[(o.open + 1)..<first.keyStart].lastIndex(of: 0x0A) {
            sep = [0x2C, 0x0A] + Array(b[(nl + 1)..<first.keyStart])
        }
        return splice(first.keyStart..<first.keyStart, item + sep)
    }
    func remove(_ o: JSONObjectSpan, _ k: Int) -> String? {
        let m = o.members
        if m.count == 1 { return splice((o.open + 1)..<o.close, []) }
        if k < m.count - 1 { return splice(m[k].keyStart..<m[k + 1].keyStart, []) }
        return splice(m[k - 1].valEnd..<m[k].valEnd, [])
    }
    if text.isEmpty { return pct == nil ? text : "{" + String(decoding: envEntry, as: UTF8.self) + "}" }
    guard let root = jsonObjectSpan(b, at: jsonSkipWS(b, 0)), jsonSkipWS(b, root.close + 1) == b.count else { return nil }
    if let ei = root.members.firstIndex(where: { $0.keyName == Array("env".utf8) }) {
        let em = root.members[ei]
        guard let env = jsonObjectSpan(b, at: em.valStart), env.close + 1 == em.valEnd else { return nil }
        if let ki = env.members.firstIndex(where: { $0.keyName == keyBytes }) {
            if pct != nil { return splice(env.members[ki].valStart..<env.members[ki].valEnd, valueBytes) }
            return env.members.count == 1 ? remove(root, ei) : remove(env, ki)
        }
        if pct == nil { return env.members.isEmpty ? remove(root, ei) : text }
        return insertFirst(env, entry)
    }
    return pct == nil ? text : insertFirst(root, envEntry)
}

/// `editAutoCompact` solo si el resultado equivale a `applyAutoCompact` sobre el original; nil si no.
func verifiedAutoCompactEdit(text: String, pct: Int?) -> String? {
    func parse(_ t: String) -> [String: Any]? {
        t.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any]
    }
    guard let orig = parse(text), let out = editAutoCompact(text: text, pct: pct), let got = parse(out),
          NSDictionary(dictionary: got).isEqual(to: applyAutoCompact(orig, pct: pct)) else { return nil }
    return out
}

private struct JSONMember { var keyStart: Int; var keyName: [UInt8]; var valStart: Int; var valEnd: Int }
private struct JSONObjectSpan { var open: Int; var close: Int; var members: [JSONMember] }

private func jsonSkipWS(_ b: [UInt8], _ i: Int) -> Int {
    var i = i
    while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    return i
}

/// `i` apunta a la comilla de apertura; devuelve el índice posterior a la de cierre.
private func jsonStringEnd(_ b: [UInt8], _ i: Int) -> Int? {
    var j = i + 1
    while j < b.count {
        if b[j] == 0x5C { j += 2; continue }
        if b[j] == 0x22 { return j + 1 }
        j += 1
    }
    return nil
}

private func jsonValueEnd(_ b: [UInt8], _ i: Int) -> Int? {
    guard i < b.count else { return nil }
    if b[i] == 0x22 { return jsonStringEnd(b, i) }
    var j = i
    if b[i] == 0x7B || b[i] == 0x5B {
        var depth = 0
        while j < b.count {
            switch b[j] {
            case 0x22:
                guard let e = jsonStringEnd(b, j) else { return nil }
                j = e
                continue
            case 0x7B, 0x5B: depth += 1
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 0 { return j + 1 }
            default: break
            }
            j += 1
        }
        return nil
    }
    while j < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[j]) { j += 1 }
    return j > i ? j : nil
}

private func jsonObjectSpan(_ b: [UInt8], at open: Int) -> JSONObjectSpan? {
    guard open < b.count, b[open] == 0x7B else { return nil }
    var members: [JSONMember] = []
    var i = jsonSkipWS(b, open + 1)
    if i < b.count, b[i] == 0x7D { return JSONObjectSpan(open: open, close: i, members: []) }
    while i < b.count, b[i] == 0x22 {
        guard let ke = jsonStringEnd(b, i) else { return nil }
        var j = jsonSkipWS(b, ke)
        guard j < b.count, b[j] == 0x3A else { return nil }
        j = jsonSkipWS(b, j + 1)
        guard let ve = jsonValueEnd(b, j) else { return nil }
        members.append(JSONMember(keyStart: i, keyName: Array(b[(i + 1)..<(ke - 1)]), valStart: j, valEnd: ve))
        i = jsonSkipWS(b, ve)
        guard i < b.count else { return nil }
        if b[i] == 0x7D { return JSONObjectSpan(open: open, close: i, members: members) }
        guard b[i] == 0x2C else { return nil }
        i = jsonSkipWS(b, i + 1)
    }
    return nil
}

private let claudeSettingsPath = claudeDir + "/settings.json"

/// nil si el archivo existe pero no es un JSON objeto; `[:]` si no existe.
private func readClaudeSettings() -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: claudeSettingsPath) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func writeClaudeSettings(text: String) throws {
    let data = Data(text.utf8)
    let url = URL(fileURLWithPath: claudeSettingsPath).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

struct ContextInfo { var used: Int }
private struct CtxEntry { var path: String?; var mtime: Date; var info: ContextInfo? }
private var ctxCache: [pid_t: CtxEntry] = [:]

/// Tokens de contexto usados por la sesión según la cola de su transcripción. Solo se llama al abrir el panel o en `--once`;
/// relee únicamente si cambió el mtime.
func sessionContext(pid: pid_t) -> ContextInfo? {
    var entry = ctxCache[pid] ?? CtxEntry(path: nil, mtime: .distantPast, info: nil)
    defer { ctxCache[pid] = entry }
    if entry.path == nil {
        guard let data = FileManager.default.contents(atPath: "\(claudeDir)/sessions/\(pid).json"),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sid = o["sessionId"] as? String, let cwd = o["cwd"] as? String else { return nil }
        entry.path = transcriptPath(sessionId: sid, cwd: cwd)
    }
    guard let path = entry.path,
          let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    else { entry.path = nil; return nil }
    if mtime == entry.mtime { return entry.info }
    entry.mtime = mtime
    entry.info = nil
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let tail: UInt64 = 256 * 1024
    try? fh.seek(toOffset: size > tail ? size - tail : 0)
    let text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
    if let u = parseContextUsage(text) {
        entry.info = ContextInfo(used: u)
    }
    return entry.info
}

func runSelfTest() {
    precondition(parseAuthLoggedIn(Data(#"{"loggedIn":true,"authMethod":"claude.ai"}"#.utf8)))
    precondition(!parseAuthLoggedIn(Data(#"{"loggedIn":false}"#.utf8)))
    precondition(!parseAuthLoggedIn(Data("basura".utf8)))
    precondition(shouldProceedSaturatingKill(freePercent: 19, orphanBytes: Config.orphanBytes + 1))
    precondition(!shouldProceedSaturatingKill(freePercent: 20, orphanBytes: Config.orphanBytes + 1))
    precondition(!shouldProceedSaturatingKill(freePercent: 5, orphanBytes: Config.orphanBytes))
    precondition(!shouldProceedSaturatingKill(freePercent: 5, orphanBytes: nil))
    precondition(!parseAuthLoggedIn(Data(#"{"loggedIn":"true"}"#.utf8)))
    let tokJSON = #"{"claudeAiOauth":{"accessToken":"tk","expiresAt":2000000}}"#
    precondition(parseOAuthToken(Data(tokJSON.utf8), now: Date(timeIntervalSince1970: 1000)) == "tk")
    precondition(parseOAuthToken(Data(tokJSON.utf8), now: Date(timeIntervalSince1970: 2000)) == nil)   // vencido
    precondition(parseOAuthToken(Data("basura".utf8), now: Date()) == nil)
    let usageJSON = #"""
    {"limits":[{"kind":"session","percent":42,"severity":"normal","resets_at":"2026-10-28T19:30:00.123456+00:00"},
    {"kind":"weekly_all","percent":80,"severity":"warning","resets_at":"2026-10-30T10:00:00+00:00"},
    {"kind":"weekly_scoped","percent":5,"severity":"normal","scope":{"model":{"display_name":"Opus"}}},
    {"kind":"otro","percent":1},{"kind":"session"}]}
    """#
    let ul = parseUsageLimits(Data(usageJSON.utf8))
    precondition(ul?.map(\.label) == ["Sesión (5 h)", "Semanal", "Semanal · Opus"] && ul?.map(\.percent) == [42, 80, 5])
    precondition(abs((ul?[0].resetsAt?.timeIntervalSince1970 ?? 0) - 1_793_215_800.123) < 0.01)   // con fracción de segundo
    precondition(ul?[1].severity == "warning" && ul?[2].resetsAt == nil)
    precondition(parseUsageLimits(Data("basura".utf8)) == nil && parseUsageLimits(Data(#"{"x":1}"#.utf8)) == nil)
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let uNow = Date(timeIntervalSince1970: 1_793_200_000)
    precondition(usageResetText(uNow.addingTimeInterval(3600), now: uNow, calendar: utc).count == 5)       // HH:mm
    precondition(usageResetText(uNow.addingTimeInterval(2 * 86400), now: uNow, calendar: utc).count > 5)   // día + hora
    let q0 = Date(timeIntervalSince1970: 1000)
    precondition(!relayShouldStop(running: true, quietSince: nil, now: q0))
    precondition(!relayShouldStop(running: true, quietSince: q0, now: q0 + Config.relayIdleStop - 1))
    precondition(relayShouldStop(running: true, quietSince: q0, now: q0 + Config.relayIdleStop))
    precondition(!relayShouldStop(running: false, quietSince: q0, now: q0 + 9999))
    var top: TopChild?
    top = largerChild(top, pid: 10, bytes: 999, root: 10)            // la raíz no cuenta
    precondition(top == nil)
    top = largerChild(top, pid: 11, bytes: 100, root: 10)
    top = largerChild(top, pid: 12, bytes: 300, root: 10)
    top = largerChild(top, pid: 13, bytes: 200, root: 10)
    precondition(top == TopChild(pid: 12, bytes: 300))
    precondition(commandName(argv0: "/usr/bin/node", exe: "/x/y") == "node")
    precondition(commandName(argv0: nil, exe: "/x/vitest") == "vitest")
    precondition(commandName(argv0: nil, exe: nil) == "?")
    precondition(commandName(argv0: String(repeating: "a", count: 200), exe: nil).count == 80)
    let line = sessionAlertLine(ts: 5, pid: 7, mb: 2048, limitMB: 1024, cwd: "/a \"b\"/c", title: "t",
                                top: TopChild(pid: 9, bytes: 3 * 1_048_576, cmd: "vitest"))
    let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    precondition(!line.contains("\n") && obj?["kind"] as? String == "session" && obj?["pid"] as? Int == 7
                 && obj?["limit_mb"] as? Int == 1024 && obj?["title"] as? String == "t")
    precondition(obj?["cwd"] as? String == "/a \"b\"/c")
    let tj = obj?["top"] as? [String: Any]
    precondition(tj?["pid"] as? Int == 9 && tj?["mb"] as? Int == 3 && tj?["cmd"] as? String == "vitest")
    let l2 = (try? JSONSerialization.jsonObject(with: Data(sessionAlertLine(ts: 1, pid: 1, mb: 1, limitMB: 1, cwd: "", title: nil, top: nil).utf8))) as? [String: Any]
    precondition(l2?["top"] is NSNull && l2?["title"] is NSNull)
    let ol = orphanAlertLine(ts: 3, pid: 4, name: "node", mb: 600, limitMB: 500, cwd: "/x")
    let oo = (try? JSONSerialization.jsonObject(with: Data(ol.utf8))) as? [String: Any]
    precondition(oo?["kind"] as? String == "orphan" && oo?["name"] as? String == "node" && oo?["mb"] as? Int == 600
                 && oo?["limit_mb"] as? Int == 500 && oo?["cwd"] as? String == "/x" && oo?["ts"] as? Int == 3)
    precondition(sanitizeName("a$(rm -rf)/b\n\"c\" é.x-1_+ ") == "arm -rfbc .x-1_+ ")
    precondition(sanitizeName(String(repeating: "a", count: 90)).count == 40)
    precondition(sanitizeText("a\nb\u{1B}[0m\tc") == "ab[0mc" && sanitizeText(String(repeating: "é", count: 300)).count == 200)
    let inj = sessionAlertLine(ts: 1, pid: 1, mb: 1, limitMB: 1, cwd: "/x\ny", title: "t\nIGNORE", top: TopChild(pid: 2, bytes: 0, cmd: "n$(x)\n"))
    precondition(!inj.contains("\n") && inj.contains("\"cmd\":\"nx\""))
    precondition(systemLowText(freePercent: 14, consumers: [("a", 1_048_576), ("Brave", 4 * 1_073_741_824), ("c", 2_097_152)])
                 == "Memoria libre baja: 14 % · mayores: Brave 4,0 GB, c 2 MB")
    precondition(systemLowText(freePercent: 9, consumers: []) == "Memoria libre baja: 9 %")
    let tmp = NSTemporaryDirectory() + "guachiman-st-\(getpid())/alerts.jsonl"
    appendAlert("uno", path: tmp, maxBytes: 8)
    appendAlert("dos", path: tmp, maxBytes: 8)
    precondition((try? String(contentsOfFile: tmp)) == "uno\ndos\n")
    appendAlert("tres", path: tmp, maxBytes: 8)   // pesa 8, no > 8: sin rotar
    appendAlert("cuatro", path: tmp, maxBytes: 8) // pesa 13 > 8: rota
    precondition((try? String(contentsOfFile: tmp + ".1")) == "uno\ndos\ntres\n" && (try? String(contentsOfFile: tmp)) == "cuatro\n")
    try? FileManager.default.removeItem(atPath: (tmp as NSString).deletingLastPathComponent)

    precondition(Orphan.name(exe: "/usr/local/bin/node", argv0: nil) == "node")
    precondition(Orphan.name(exe: "/x/y", argv0: "next-server (v14)") == "next-server")
    precondition(Orphan.name(exe: nil, argv0: "playwright-core run") == "playwright-core")
    precondition(Orphan.name(exe: "/opt/VITEST", argv0: nil) == "vitest")
    precondition(Orphan.name(exe: "/bin/zsh", argv0: "nodemon") == nil)
    precondition(Orphan.name(exe: "/bin/zsh", argv0: "claude") == nil)
    precondition(Orphan.name(exe: nil, argv0: nil) == nil)

    var t = SustainedTracker<pid_t>()
    let t0 = Date()
    precondition(t.update(1, over: true, now: t0) == 0)
    precondition(t.update(1, over: true, now: t0 + 61) >= Config.orphanAlertAfter)
    precondition(t.update(1, over: true, now: t0 + 61) < Config.orphanCloseAfter)
    precondition(t.update(1, over: true, now: t0 + 601) >= Config.orphanCloseAfter)
    precondition(t.update(1, over: false, now: t0 + 602) == 0)
    precondition(t.update(1, over: true, now: t0 + 700) == 0)   // reinicia al volver a superar
    _ = t.update(2, over: true, now: t0)
    t.retain([1])
    precondition(t.update(2, over: true, now: t0 + 900) == 0)   // pid muerto olvidado

    var ts = SustainedTracker<String>()
    _ = ts.update("a", over: true, now: t0)
    precondition(ts.update("a", over: true, now: t0 + 5) == 5)
    ts.retain([])
    precondition(ts.update("a", over: true, now: t0 + 9) == 0)

    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    precondition(appGroup(path: chrome, argv0: nil, pid: 5) == ("/Applications/Google Chrome.app/", "Google Chrome"))
    precondition(appGroup(path: "/usr/bin/python3", argv0: nil, pid: 7) == ("pid:7", "python3"))
    precondition(appGroup(path: "/usr/bin/python3", argv0: nil, pid: 8).key != appGroup(path: "/usr/bin/python3", argv0: nil, pid: 7).key)
    precondition(appGroup(path: nil, argv0: "/opt/x/tool", pid: 9) == ("pid:9", "tool"))
    precondition(appGroup(path: nil, argv0: nil, pid: 9).name == "?")
    precondition(cpuPercent(prev: 0, cur: 1_000_000_000, wall: 1, timebase: (1, 1)) == 100)
    precondition(abs(cpuPercent(prev: 10, cur: 24_000_010, wall: 2, timebase: (125, 3)) - 50) < 0.0001)
    precondition(cpuPercent(prev: 5, cur: 9, wall: 0, timebase: (1, 1)) == 0)
    precondition(cpuPercent(prev: 9, cur: 5, wall: 1, timebase: (1, 1)) == 0)

    precondition(rowColor(bytes: 2000, cpu: 0.5, ramLimit: 1000, cpuLimit: 80, idleFor: 120) == .gray)   // gris manda sobre rojo
    precondition(rowColor(bytes: 2000, cpu: 0.5, ramLimit: 1000, cpuLimit: 80, idleFor: 119) == .red)
    precondition(rowColor(bytes: 10, cpu: 0, ramLimit: 1000, cpuLimit: 80, idleFor: 60) == .green)       // < 120 s no es gris
    precondition(rowColor(bytes: 10, cpu: 5, ramLimit: 1000, cpuLimit: 80, idleFor: 500) == .green)      // con CPU >= 1 % no es gris
    precondition(rowColor(bytes: 1000, cpu: 10, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .yellow)    // igual al umbral no es rojo
    precondition(rowColor(bytes: 10, cpu: 81, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .red)
    precondition(rowColor(bytes: 750, cpu: 10, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .yellow)
    precondition(rowColor(bytes: 749, cpu: 10, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .green)
    precondition(rowColor(bytes: 10, cpu: 60, ramLimit: 1000, cpuLimit: 80, idleFor: 0) == .yellow)
    precondition(rowColor(bytes: 10, cpu: 500, ramLimit: 1000, cpuLimit: nil, idleFor: 0) == .green)    // huérfano: sin umbral de CPU

    precondition(freeMemoryColor(freePercent: 19) == .red && freeMemoryColor(freePercent: 20) == .yellow)
    precondition(freeMemoryColor(freePercent: 40) == .yellow && freeMemoryColor(freePercent: 41) == .green)
    precondition(cpuLoadPercent(prev: (10, 100), cur: (35, 200)) == 25)
    precondition(cpuLoadPercent(prev: (10, 100), cur: (10, 100)) == 0)
    let now = Date()
    precondition(!pauseActive(until: nil, now: now))
    precondition(pauseActive(until: now + 10, now: now))
    precondition(!pauseActive(until: now - 1, now: now))

    precondition(parseVersion("v0.7.0") == [0, 7, 0] && parseVersion("0.7.0") == [0, 7, 0] && parseVersion("0.7") == [0, 7])
    precondition(parseVersion("") == nil && parseVersion("v") == nil && parseVersion("abc") == nil)
    precondition(parseVersion("0.8.0-beta") == nil && parseVersion("1..2") == nil && parseVersion("0.7.") == nil)
    precondition(isNewerVersion("0.10.0", than: "0.9.9") && !isNewerVersion("0.9.9", than: "0.10.0"))
    precondition(!isNewerVersion("0.7", than: "0.7.0") && !isNewerVersion("0.7.0", than: "0.7"))
    precondition(isNewerVersion("v0.7.1", than: "0.7") && !isNewerVersion("junk", than: "0.7"))
    precondition(latestVersion(fromTagsJSON: Data(#"[{"name":"v0.6.2"},{"name":"v0.7.0"},{"name":"v0.8.0-beta"},{"name":"foo"}]"#.utf8)) == "0.7.0")
    precondition(latestVersion(fromTagsJSON: Data("[]".utf8)) == nil)
    precondition(latestVersion(fromTagsJSON: Data(#"[{"name":"foo"},{"name":"v1-rc"},{}]"#.utf8)) == nil)
    precondition(latestVersion(fromTagsJSON: Data(#"{"name":"v0.8.0"}"#.utf8)) == nil && latestVersion(fromTagsJSON: Data("no".utf8)) == nil)
    precondition(shouldCheckForUpdate(last: nil, now: now))
    precondition(!shouldCheckForUpdate(last: now - 60, now: now))
    precondition(shouldCheckForUpdate(last: now - Config.updateCheckInterval, now: now))

    let d = launchAgentPlist(executable: "/a/Guachiman")
    precondition(d["Label"] as? String == "io.github.guachiman")
    precondition(d["ProgramArguments"] as? [String] == ["/a/Guachiman"])
    precondition(d["RunAtLoad"] as? Bool == true)
    precondition((d["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    precondition(d["ProcessType"] as? String == "Interactive")
    precondition((try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)) != nil)
    precondition(encodedProjectDir("/Users/xklbr/Documents/projects/guachiman") == "-Users-xklbr-Documents-projects-guachiman")
    precondition(encodedProjectDir("/a b/c.d_e") == "-a-b-c-d-e")
    let jl = "{\"type\":\"ai-title\",\"aiTitle\":\"uno\"}\n{\"type\":\"custom-title\",\"customTitle\":\"mio\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"dos\"}\n"
    precondition(extractSessionTitle(jl) == "mio")
    precondition(extractSessionTitle("{\"type\":\"ai-title\",\"aiTitle\":\"uno\"}\nbasura\n{\"type\":\"ai-title\",\"aiTitle\":\"dos\"}") == "dos")
    precondition(extractSessionTitle("{\"type\":\"user\"}\n") == nil)
    precondition(truncatedTitle(String(repeating: "x", count: 60)).count == 50 && truncatedTitle("hola") == "hola")
    let tr = "{\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":3}}}\n"
        + "{\"message\":{\"model\":\"<synthetic>\",\"usage\":{\"input_tokens\":0}}}\n{\"type\":\"user\"}\nrota{\"usage\"\n"
    precondition(parseContextUsage(tr) == 24 && parseContextUsage("{\"type\":\"user\"}") == nil)
    precondition(formatContextTokens(0) == "ctx <1k" && formatContextTokens(999) == "ctx <1k" && formatContextTokens(1000) == "ctx 1k")
    precondition(formatContextTokens(191_600) == "ctx 192k" && formatContextTokens(1_250_000) == "ctx 1250k")
    let base: [String: Any] = ["model": "opus", "env": ["FOO": "1"]]
    let on = applyAutoCompact(base, pct: 70)
    precondition(autoCompactPct(on) == 70 && (on["env"] as? [String: Any])?["FOO"] as? String == "1" && on["model"] as? String == "opus")
    precondition(autoCompactPct(applyAutoCompact(on, pct: nil)) == nil && (applyAutoCompact(on, pct: nil)["env"] as? [String: Any])?["FOO"] as? String == "1")
    precondition(applyAutoCompact(applyAutoCompact([:], pct: 50), pct: nil).isEmpty && autoCompactPct(["env": [autoCompactEnvKey: 60]]) == 60)
    let K = autoCompactEnvKey
    func chk(_ src: String, _ pct: Int?, _ want: String?) {
        let out = editAutoCompact(text: src, pct: pct)
        precondition(out == want, "editAutoCompact: \(String(describing: out))")
        precondition(verifiedAutoCompactEdit(text: src, pct: pct) == (want == nil ? nil : out))
    }
    let pre = "{\n  \"permissions\": {\n    \"allow\": [\"Bash(ls)\"]\n  },\n"
    let post = "  \"model\": \"opus\"\n}\n"
    let envNoKey = "  \"env\": {\n    \"ZED\": \"1\",\n    \"ALPHA\": \"2\"\n  },\n"
    let envMid = "  \"env\": {\n    \"ZED\": \"1\",\n    \"\(K)\": \"50\",\n    \"ALPHA\": \"2\"\n  },\n"
    let envOnly = "  \"env\": {\n    \"\(K)\": 60\n  },\n"
    // a
    chk(pre + envMid + post, 70, pre + envMid.replacingOccurrences(of: "\"50\"", with: "\"70\"") + post)
    chk(pre + envMid + post, nil, pre + envNoKey + post)
    chk(pre + "  \"env\": {\n    \"ZED\": \"1\",\n    \"\(K)\": \"50\"\n  },\n" + post, nil,
        pre + "  \"env\": {\n    \"ZED\": \"1\"\n  },\n" + post)
    chk(pre + "  \"env\": {\n    \"\(K)\": \"50\",\n    \"ZED\": \"1\"\n  },\n" + post, nil,
        pre + "  \"env\": {\n    \"ZED\": \"1\"\n  },\n" + post)
    // b
    chk(pre + envNoKey + post, 70, pre + "  \"env\": {\n    \"\(K)\": \"70\",\n    \"ZED\": \"1\",\n    \"ALPHA\": \"2\"\n  },\n" + post)
    chk("{\"env\": {\"ZED\": \"1\"}}", 70, "{\"env\": {\"\(K)\": \"70\", \"ZED\": \"1\"}}")
    chk(pre + "  \"env\": {},\n" + post, 70, pre + "  \"env\": {\"\(K)\": \"70\"},\n" + post)
    chk(pre + envNoKey + post, nil, pre + envNoKey + post)
    // c
    chk(pre + post, 70, "{\n  \"env\": {\"\(K)\": \"70\"},\n  \"permissions\": {\n    \"allow\": [\"Bash(ls)\"]\n  },\n" + post)
    chk("{}\n", 70, "{\"env\": {\"\(K)\": \"70\"}}\n")
    chk("{}", 70, "{\"env\": {\"\(K)\": \"70\"}}")
    chk("", 70, "{\"env\": {\"\(K)\": \"70\"}}")
    chk("", nil, "")
    // d
    chk(pre + envOnly + post, nil, pre + post)
    chk(pre + "  \"env\": {},\n" + post, nil, pre + post)
    chk("{\n  \"env\": {\"\(K)\": \"1\"}\n}\n", nil, "{}\n")
    chk("{\n  \"model\": \"opus\",\n  \"env\": {\"\(K)\": \"1\"}\n}\n", nil, "{\n  \"model\": \"opus\"\n}\n")
    // e
    chk(pre + envMid + "  \"model\": \"opus\"\n}", 80, pre + envMid.replacingOccurrences(of: "\"50\"", with: "\"80\"") + "  \"model\": \"opus\"\n}")
    chk("{\"model\": 1}", 70, "{\"env\": {\"\(K)\": \"70\"}, \"model\": 1}")
    // la clave y "env" dentro de strings de otras claves no se confunden
    let note = "  \"note\": \"ver \\\"env\\\": {\\\"\(K)\\\": \\\"x\\\"} aquí\",\n"
    chk("{\n" + note + envNoKey + post, 70, "{\n" + note + "  \"env\": {\n    \"\(K)\": \"70\",\n    \"ZED\": \"1\",\n    \"ALPHA\": \"2\"\n  },\n" + post)
    chk("{\n" + note + post, 70, "{\n  \"env\": {\"\(K)\": \"70\"},\n" + note + post)
    chk("{\n" + note + "  \"env\": {\n    \"\(K)\": \"5\"\n  }\n}\n", nil, "{\n" + note.dropLast(2) + "\n}\n")
    // JSON inválido
    chk("{\"a\": 1,}", 70, nil)
    chk("{\"a\": \"x\": \"y\"}", 70, nil)
    chk("{\"env\": 3}", 70, nil)
    chk("[1]", 70, nil)
    chk("{\"a\": 1} basura", 70, nil)
    precondition(verifiedAutoCompactEdit(text: "   ", pct: 70) == nil)
    print("selftest OK")
}

// MARK: - Lectura de procesos (libproc / sysctl)

struct Session {
    let pid: pid_t
    let label: String
    let cwd: String
    let bytes: UInt64
    let cpu: Double          // % de un núcleo, suma del árbol
    let tree: [pid_t]
    var top: TopChild? = nil   // solo si supera el umbral
}

struct OrphanProc {
    let pid: pid_t
    let name: String
    let bytes: UInt64
    let cpu: Double
    let tree: [pid_t]   // el huérfano y todos sus descendientes
}

struct AppUsage {
    let key: String
    let name: String
    var bytes: UInt64 = 0
    var cpu = 0.0   // % de un núcleo
    var pids: [pid_t] = []
}

struct Snapshot {
    let sessions: [Session]   // ordenadas por RAM desc
    let orphans: [OrphanProc]
    let apps: [AppUsage]      // resto de procesos agrupados por app, por RAM desc
    let freePercent: Int
}

func physicalMemory() -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &value, &size, nil, 0)
    return value
}

func freeMemoryPercent() -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0)
    return Int(value)
}

func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return [] }
    return pids.prefix(Int(got)).filter { $0 > 0 }
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

/// Buffer reutilizable para KERN_PROCARGS2 (se evita reservar 64 KB en cada llamada).
private var procArgsBuffer = [UInt8](repeating: 0, count: 1 << 16)

/// argv[0] vía sysctl KERN_PROCARGS2. Los binarios de terminal viven en
/// `.../claude/versions/<ver>`, así que ni el path ni p_comm dicen "claude"; argv[0] sí.
func argv0(_ pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = procArgsBuffer.count                    // fijo y sobrado: evita carreras entre tamaño y lectura
    guard sysctl(&mib, 3, &procArgsBuffer, &size, nil, 0) == 0, size > 4 else { return nil }
    let buf = procArgsBuffer
    var i = 4                                          // salta argc
    while i < size, buf[i] != 0 { i += 1 }             // exec path
    while i < size, buf[i] == 0 { i += 1 }             // relleno
    let start = i
    while i < size, buf[i] != 0 { i += 1 }
    guard i > start else { return nil }
    return String(decoding: buf[start..<i], as: UTF8.self)
}

func isClaude(_ pid: pid_t) -> Bool {
    if let path = executablePath(pid), (path as NSString).lastPathComponent == Config.sessionExecutable { return true }
    if let arg = argv0(pid), (arg as NSString).lastPathComponent == Config.sessionExecutable { return true }
    return false
}

func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    return info
}

/// Lecturas previas de CPU (pid → tiempo en unidades Mach) para calcular el delta entre sondeos.
private var cpuPrev: [pid_t: UInt64] = [:]
private var cpuPrevAt: Date?
private let timebase: (numer: UInt32, denom: UInt32) = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return (t.numer, t.denom)
}()

func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard n > 0 else { return nil }
    return String(cString: buffer)
}

func currentDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

private let sessionLimitBytes = UInt64(Double(physicalMemory()) * Config.sessionFraction)

func takeSnapshot() -> Snapshot {
    var parents: [pid_t: pid_t] = [:]
    var children: [pid_t: [pid_t]] = [:]
    var claudePids = Set<pid_t>()

    for pid in allPids() {
        guard let ppid = parentPid(pid) else { continue }
        parents[pid] = ppid
        children[ppid, default: []].append(pid)
        if isClaude(pid) { claudePids.insert(pid) }
    }

    // Raíces: claude sin ancestro claude.
    let roots = claudePids.filter { pid in
        var current = parents[pid]
        var hops = 0
        while let p = current, p > 1, hops < 256 {
            if claudePids.contains(p) { return false }
            current = parents[p]
            hops += 1
        }
        return true
    }

    // Una sola lectura de taskinfo por pid da RSS y tiempo de CPU; la primera lectura de un pid da CPU 0.
    let sampledAt = Date()
    let wall = cpuPrevAt.map { sampledAt.timeIntervalSince($0) } ?? 0
    var cpuNow: [pid_t: UInt64] = [:]
    func read(_ pid: pid_t, cpu: inout Double) -> UInt64? {
        guard let ti = taskInfo(pid) else { return nil }
        let ticks = ti.pti_total_user + ti.pti_total_system
        cpuNow[pid] = ticks
        if let prev = cpuPrev[pid] { cpu += cpuPercent(prev: prev, cur: ticks, wall: wall, timebase: timebase) }
        return ti.pti_resident_size
    }

    func tree(_ root: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            out.append(pid)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return out
    }

    var sessions: [Session] = []
    var sessionPids = Set<pid_t>()
    for root in roots {
        let pids = tree(root)
        sessionPids.formUnion(pids)
        var total: UInt64 = 0
        var cpu = 0.0
        var best: TopChild?
        for p in pids {
            let r = read(p, cpu: &cpu) ?? 0
            total += r
            best = largerChild(best, pid: p, bytes: r, root: root)
        }
        let cwd = currentDirectory(root) ?? ""
        let label = cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent
        if total > sessionLimitBytes, var b = best {   // solo sesiones sobre el umbral pagan estas lecturas
            b.cmd = commandName(argv0: argv0(b.pid), exe: executablePath(b.pid))
            best = b
        } else { best = nil }
        sessions.append(Session(pid: root, label: label, cwd: cwd, bytes: total, cpu: cpu, tree: pids, top: best))
    }
    sessions.sort { $0.bytes > $1.bytes }

    // Huérfanos: ppid 1, nombre conocido, fuera de (y sin claude dentro de) árboles de sesión.
    var orphans: [OrphanProc] = []
    for (pid, ppid) in parents where ppid == 1 && !claudePids.contains(pid) && !sessionPids.contains(pid) {
        guard let name = Orphan.name(exe: executablePath(pid), argv0: argv0(pid)) else { continue }
        let pids = tree(pid)
        if !sessionPids.isDisjoint(with: pids) { continue }
        var cpu = 0.0
        var bytes: UInt64 = 0
        for p in pids { bytes += read(p, cpu: &cpu) ?? 0 }
        orphans.append(OrphanProc(pid: pid, name: name, bytes: bytes, cpu: cpu, tree: pids))
    }
    orphans.sort { $0.bytes > $1.bytes }

    // Apps: todo lo que no es sesión ni huérfano, agrupado por .app.
    let excluded = sessionPids.union(orphans.flatMap { $0.tree })
    var groups: [String: AppUsage] = [:]
    for pid in parents.keys where !excluded.contains(pid) {
        var cpu = 0.0
        guard let rss = read(pid, cpu: &cpu) else { continue }
        let path = executablePath(pid)
        let g = appGroup(path: path, argv0: path == nil ? argv0(pid) : nil, pid: pid)
        groups[g.key, default: AppUsage(key: g.key, name: g.name)].bytes += rss
        groups[g.key]!.cpu += cpu
        groups[g.key]!.pids.append(pid)
    }
    cpuPrev = cpuNow
    cpuPrevAt = sampledAt
    let apps = groups.values.sorted { $0.bytes > $1.bytes }
    return Snapshot(sessions: sessions, orphans: orphans, apps: apps, freePercent: freeMemoryPercent())
}

// MARK: - Formato

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    let es = Locale(identifier: "es")
    if gb >= 1 { return String(format: "%.1f GB", locale: es, gb) }
    return String(format: "%.0f MB", locale: es, Double(bytes) / 1_048_576)
}

// MARK: - Modo --once

func runOnce() {
    _ = takeSnapshot()                      // primera lectura de CPU
    Thread.sleep(forTimeInterval: 1)
    let snap = takeSnapshot()
    let mem = physicalMemory()
    let limit = UInt64(Double(mem) * Config.sessionFraction)
    // Con una sola muestra de 1 s no se puede saber si una fila está inactiva: nunca sale "gris".
    func status(_ bytes: UInt64, _ cpu: Double, _ ramLimit: UInt64, _ cpuLimit: Double?) -> String {
        rowColor(bytes: bytes, cpu: cpu, ramLimit: ramLimit, cpuLimit: cpuLimit, idleFor: 0).rawValue
    }
    print("PID\tETIQUETA\tTITULO\tTOTAL_MB\tESTADO\tCTX\tCWD")
    for s in snap.sessions {
        print("\(s.pid)\t\(s.label)\t\(sessionTitle(pid: s.pid).map(truncatedTitle) ?? "-")\t\(s.bytes / 1_048_576)\t\(status(s.bytes, s.cpu, limit, Config.appCpuPercent))\t\(sessionContext(pid: s.pid).map { formatContextTokens($0.used) } ?? "-")\t\(s.cwd)")
    }
    if snap.sessions.isEmpty { print("(sin sesiones de Claude)") }
    print("")
    print("Candidatos a huérfano (pid\tnombre\tMB\testado)")
    for o in snap.orphans { print("\(o.pid)\t\(o.name)\t\(o.bytes / 1_048_576)\t\(status(o.bytes, o.cpu, Config.orphanBytes, nil))") }
    if snap.orphans.isEmpty { print("(ninguno)") }
    print("")
    print("Apps (nombre\tMB\tCPU %\testado)")
    for a in snap.apps.prefix(10) {
        print("\(a.name)\t\(a.bytes / 1_048_576)\t\(Int(a.cpu.rounded()))\t\(status(a.bytes, a.cpu, limit, Config.appCpuPercent))")
    }
    print("")
    print("Memoria libre: \(snap.freePercent)%")
    print("RAM física: \(mem / 1_048_576) MB")
    print("Umbral de sesión: \(limit / 1_048_576) MB (\(Int(Config.sessionFraction * 100))% de la RAM, sostenido \(Int(Config.sessionSustained)) s)")
    print("Umbral de app: \(limit / 1_048_576) MB sostenido \(Int(Config.sessionSustained)) s, o \(Int(Config.appCpuPercent)) % de CPU sostenido \(Int(Config.appCpuSustained)) s")
    print("Umbral de sistema: memoria libre < \(Config.systemFreeMinPercent)%")
}

// MARK: - Notificaciones (solo UNUserNotificationCenter)

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var isAuthorized = false

    /// Pide autorización (si falta) y luego refresca el estado; `completion` corre en main.
    func start(completion: @escaping () -> Void = {}) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refresh(completion: completion)
        }
    }

    /// Relee el estado real en Ajustes del Sistema; `completion` corre en main.
    func refresh(completion: @escaping () -> Void = {}) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                self?.isAuthorized = status == .authorized || status == .provisional
                completion()
            }
        }
    }

    // Sin esto macOS no muestra el banner si la app está activa (p. ej. con el menú abierto).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func send(_ text: String) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Guachiman"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }   // si falla, el ícono rojo sigue avisando
    }
}

// MARK: - Aplicación

/// Qué cerrar al pulsar detener en una fila; se captura al construir el menú.
struct KillTarget {
    let name: String
    let bytes: UInt64
    let pids: [pid_t]        // árbol en preorden (la raíz primero)
    let appPath: String?     // grupo de una app (.app): se cierra con NSRunningApplication
    let expandTree: Bool     // proceso suelto: al cerrar se incluyen sus descendientes
}

/// ¿Es seguro enviarle señales? Nunca pid <= 1 ni Guachiman.
func signalable(_ pid: pid_t) -> Bool { pid > 1 && pid != getpid() }
func alive(_ pid: pid_t) -> Bool { signalable(pid) && kill(pid, 0) == 0 }

/// Descendientes de `root` (incluido), en preorden, con una lectura nueva de la tabla de procesos.
func liveTree(_ root: pid_t) -> [pid_t] {
    var children: [pid_t: [pid_t]] = [:]
    for pid in allPids() { if let pp = parentPid(pid) { children[pp, default: []].append(pid) } }
    var out: [pid_t] = []
    var stack = [root]
    var seen = Set<pid_t>()
    while let pid = stack.popLast() {
        guard seen.insert(pid).inserted else { continue }
        out.append(pid)
        stack.append(contentsOf: children[pid] ?? [])
    }
    return out
}

// MARK: - Panel isla (vistas AppKit; solo existen mientras el panel está abierto)

class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Panel sin activar la app: puede ser key para recibir Esc, nunca main.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Paleta del popover (tokens oscuros del diseño).
enum Pal {
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static let popover = hex(0x161616)
    static let foreground = hex(0xededed)
    static let muted = hex(0x9a9a9a)
    static let accent = hex(0x262626)
    static let primary = hex(0x00d495)
    static let destructive = hex(0xe5484d)
    static let border = hex(0x2a2a2a)
}

func panelLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false,
                color: NSColor = Pal.foreground, align: NSTextAlignment = .left, frame: NSRect) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.frame = frame
    return l
}

/// Botón sin borde con fondo `accent` al pasar el cursor (IA y ajustes).
final class HoverButton: NSButton {
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled { layer?.backgroundColor = Pal.accent.cgColor }
    }

    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}

/// Fila del panel: punto de estado, nombre, memoria y, a la derecha, CPU (o botón de detener al pasar el cursor).
final class PanelRow: FlippedView {
    static let height: CGFloat = 24
    private let cpuLabel: NSTextField
    private var stopButton: NSButton?
    private var area: NSTrackingArea?

    init(width: CGFloat, text: String, memory: String, cpu: String, color: NSColor, stopTag: Int?, stopLabel: String,
         stopTip: String, target: AnyObject, action: Selector, ctx: (text: String, color: NSColor)? = nil) {
        let colW: CGFloat = 30, memW: CGFloat = 64
        let colX = width - 8 - colW
        let memX = colX - 8 - memW
        cpuLabel = panelLabel(cpu, size: 11, mono: true, color: Pal.muted, align: .right,
                              frame: NSRect(x: colX, y: 5, width: colW, height: 14))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: PanelRow.height))
        wantsLayer = true
        layer?.cornerRadius = 6
        let dot = NSView(frame: NSRect(x: 8, y: 9, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        addSubview(dot)
        let ctxW: CGFloat = ctx == nil ? 0 : 60
        addSubview(panelLabel(text, size: 12.5, frame: NSRect(x: 22, y: 4, width: memX - 8 - 22 - ctxW, height: 16)))
        if let ctx {
            addSubview(panelLabel(ctx.text, size: 10.5, mono: true, color: ctx.color, align: .right,
                                  frame: NSRect(x: memX - 4 - ctxW, y: 5, width: ctxW, height: 14)))
        }
        addSubview(panelLabel(memory, size: 11, mono: true, color: Pal.muted, align: .right,
                              frame: NSRect(x: memX, y: 5, width: memW, height: 14)))
        addSubview(cpuLabel)
        if let stopTag {
            let b = NSButton(frame: NSRect(x: width - 8 - 18, y: 3, width: 18, height: 18))
            b.image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
                return true
            }
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleNone
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = Pal.destructive.cgColor
            b.layer?.cornerRadius = 4
            b.toolTip = stopTip
            b.setAccessibilityLabel(stopLabel)
            b.tag = stopTag
            b.target = target
            b.action = action
            b.isHidden = true
            addSubview(b)
            stopButton = b
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Pal.accent.cgColor
        if let stopButton { cpuLabel.isHidden = true; stopButton.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        if let stopButton { cpuLabel.isHidden = false; stopButton.isHidden = true }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let notifier = Notifier()
    private let memory = physicalMemory()
    private var overSince: [pid_t: Date] = [:]
    private var orphanTracker = SustainedTracker<pid_t>()
    private var appRamTracker = SustainedTracker<String>()
    private var appCpuTracker = SustainedTracker<String>()
    private var closedAttempted = Set<pid_t>()
    private var pausedUntil: Date?
    private var lastSnap: Snapshot?
    private var idleTracker = SustainedTracker<String>()   // desde cuándo cada fila está con CPU < 1 %
    private var lastIdle: [String: TimeInterval] = [:]
    private var rowTargets: [KillTarget] = []
    private var panel: IslandPanel?
    private var usageLimits: [UsageLimit]?   // último resultado (nil = sin datos)
    private var usageFetchedAt: Date?       // caché de 5 min; sin timers, solo se consulta al abrir el panel
    private var usageFetching = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var menuOpen = false
    private var cpuTotal: Double?
    private var cpuTicksPrev: (busy: UInt64, total: UInt64)?
    private var debugPanelShown = false
    private let agentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(Config.agentLabel).plist")
    private var autoClose: Bool {
        get { UserDefaults.standard.bool(forKey: Config.autoCloseKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.autoCloseKey) }
    }
    private var autoKillSaturating: Bool {
        get { UserDefaults.standard.bool(forKey: Config.autoKillSaturatingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.autoKillSaturatingKey) }
    }
    private var pendingKill: (pid: pid_t, name: String, work: DispatchWorkItem)?   // cierre con cuenta atrás
    private var aiEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Config.aiKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.aiKey) }
    }
    private var aiLoginFailed = false
    private var relayRunning = false         // el relay se lanzó bajo demanda y aún no se detuvo
    private var relayQuietSince: Date?       // desde cuándo no hay sesión ni huérfano en alerta
    private var termSource: DispatchSourceSignal?
    private var lastAlert: [String: (date: Date, value: Double)] = [:]
    private var timer: Timer?
    private var availableVersion: String?
    private var checkingUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp])
        }
        // Limpieza única del directorio `pending/` de versiones anteriores (inofensiva si no existe).
        try? FileManager.default.removeItem(atPath: Config.supportDir + "/pending")
        truncateAlerts()   // el relay es bajo demanda: al arrancar no hay ciclo anterior
        if aiEnabled { _ = checkAILogin() }
        // SIGTERM (p. ej. `brew services stop`): detiene el relay antes de salir.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in self?.quit() }
        src.resume()
        termSource = src
        // Otra instancia (p. ej. la copia de ~/Applications abierta desde Spotlight) pide abrir el panel.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(showPanelNotification), object: nil, queue: .main) { [weak self] _ in
            self?.openPanel()
        }
        // Aviso único tras una actualización: compara con la versión de la ejecución anterior.
        var updatedNote: String?
        if let cur = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let key = "lastVersion"
            if let prev = UserDefaults.standard.string(forKey: key), prev != cur {
                updatedNote = "Guachiman actualizado a \(cur)"
            }
            UserDefaults.standard.set(cur, forKey: key)
        }
        cpuTicksPrev = cpuTicks()   // base para que el primer sondeo ya muestre CPU total
        let wantsTest = CommandLine.arguments.contains("--notify-test")
        notifier.start { [weak self] in
            guard let self else { return }
            if wantsTest { self.notifier.send("Prueba: Guachiman puede notificarte") }
            if let note = updatedNote { self.notifier.send(note) }
            self.poll()
            self.checkForUpdate(force: false)
        }
    }

    /// `force`: ignora el intervalo y avisa del resultado aunque no haya novedad.
    private func checkForUpdate(force: Bool) {
        let ud = UserDefaults.standard
        guard !checkingUpdate, force || shouldCheckForUpdate(last: ud.object(forKey: Config.lastUpdateCheckKey) as? Date, now: Date())
        else { return }
        checkingUpdate = true
        fetchLatestVersion { [weak self] latest in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingUpdate = false
                ud.set(Date(), forKey: Config.lastUpdateCheckKey)
                let cur = installedVersion
                guard let v = latest else {
                    if force { self.notifier.send("No se pudo comprobar la versión") }
                    return
                }
                guard isNewerVersion(v, than: cur) else {
                    self.availableVersion = nil
                    if force { self.notifier.send("Ya tienes la última versión (\(cur))") }
                    return
                }
                self.availableVersion = v
                if ud.string(forKey: Config.notifiedVersionKey) != v, !pauseActive(until: self.pausedUntil, now: Date()) {
                    self.notifier.send("Guachiman \(v) disponible. Actualiza desde el menú.")
                    ud.set(v, forKey: Config.notifiedVersionKey)
                }
            }
        }
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in self?.poll() }
        t.tolerance = interval * 0.1
        timer = t
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func poll() {
        // Releer el permiso en cada sondeo; el resto del ciclo corre con el valor actualizado.
        notifier.refresh { [weak self] in self?.runPoll() }
    }

    private func runPoll() {
        let snap = takeSnapshot()
        let now = Date()
        if let cur = cpuTicks() {
            if let prev = cpuTicksPrev { cpuTotal = cpuLoadPercent(prev: prev, cur: cur) }
            cpuTicksPrev = cur
        }
        let limit = UInt64(Double(memory) * Config.sessionFraction)

        // Inactividad: desde cuándo cada fila lleva con CPU < 1 % (y se olvidan las que desaparecen).
        var idle: [String: TimeInterval] = [:]
        func track(_ key: String, _ cpu: Double) {
            idle[key] = idleTracker.update(key, over: cpu < Config.idleCpuPercent, now: now)
        }
        for s in snap.sessions { track("session:\(s.pid)", s.cpu) }
        for o in snap.orphans { track("orphan:\(o.pid)", o.cpu) }
        for a in snap.apps { track(a.key, a.cpu) }
        idleTracker.retain(Set(idle.keys))
        lastIdle = idle

        // Sesiones por encima del umbral.
        var anyOver = false
        let livePids = Set(snap.sessions.map { $0.pid })
        overSince = overSince.filter { livePids.contains($0.key) }
        for s in snap.sessions {
            if s.bytes > limit {
                anyOver = true
                let since = overSince[s.pid] ?? now
                overSince[s.pid] = since
                if now.timeIntervalSince(since) >= Config.sessionSustained {
                    var text = "Sesión \(sessionLabel(s)) usa \(formatBytes(s.bytes)) (pid \(s.pid))"
                    if let t = s.top { text += " (mayor: \(t.cmd) \(formatBytes(t.bytes)))" }
                    if alert(key: "session:\(s.pid)", value: Double(s.bytes), text: text, now: now), aiEnabled {
                        startRelayIfNeeded()
                        appendAlert(sessionAlertLine(
                            ts: Int(now.timeIntervalSince1970), pid: s.pid, mb: s.bytes / 1_048_576,
                            limitMB: limit / 1_048_576, cwd: s.cwd, title: cachedSessionTitle(pid: s.pid), top: s.top))
                    }
                }
            } else {
                overSince[s.pid] = nil
            }
        }

        // Huérfanos: aviso a los 60 s, cierre opcional a los 10 min.
        var orphanOver = false
        let orphanPids = Set(snap.orphans.map { $0.pid })
        orphanTracker.retain(orphanPids)
        closedAttempted.formIntersection(orphanPids)
        for o in snap.orphans {
            let dur = orphanTracker.update(o.pid, over: o.bytes > Config.orphanBytes, now: now)
            guard o.bytes > Config.orphanBytes else { continue }
            if dur >= Config.orphanAlertAfter {
                orphanOver = true
                if alert(key: "orphan:\(o.pid)", value: Double(o.bytes),
                         text: "Huérfano \(o.name) usa \(formatBytes(o.bytes)) (pid \(o.pid))", now: now), aiEnabled {
                    startRelayIfNeeded()
                    appendAlert(orphanAlertLine(
                        ts: Int(now.timeIntervalSince1970), pid: o.pid, name: o.name, mb: o.bytes / 1_048_576,
                        limitMB: Config.orphanBytes / 1_048_576, cwd: currentDirectory(o.pid) ?? ""))
                }
            }
            if dur >= Config.orphanCloseAfter, autoClose, !pauseActive(until: pausedUntil, now: now),
               !closedAttempted.contains(o.pid) {
                closedAttempted.insert(o.pid)
                close(o)
            }
        }

        // Apps: RAM > 15% sostenida 60 s, CPU > 80% de un núcleo sostenida 120 s. Solo avisa, nunca cierra.
        // Relay bajo demanda: se apaga tras 5 min continuos sin sesión ni huérfano en alerta (el amarillo no lo mantiene).
        relayQuietSince = anyOver || orphanOver ? nil : (relayQuietSince ?? now)
        if relayShouldStop(running: relayRunning, quietSince: relayQuietSince, now: now) { stopRelay(wait: false) }
        var appOver = false
        let appKeys = Set(snap.apps.map { $0.key })
        appRamTracker.retain(appKeys)
        appCpuTracker.retain(appKeys)
        for a in snap.apps {
            if appRamTracker.update(a.key, over: a.bytes > limit, now: now) >= Config.sessionSustained {
                appOver = true
                alert(key: "appram:\(a.key)", value: Double(a.bytes),
                      text: "\(a.name) usa \(formatBytes(a.bytes)) de RAM", now: now)
            }
            if appCpuTracker.update(a.key, over: a.cpu > Config.appCpuPercent, now: now) >= Config.appCpuSustained {
                appOver = true
                alert(key: "appcpu:\(a.key)", value: a.cpu,
                      text: "\(a.name) usa \(Int(a.cpu.rounded())) % de CPU sostenido", now: now)
            }
        }
        pruneTitleCache(live: livePids)
        lastAlert = lastAlert.filter { k, _ in
            if k.hasPrefix("session:") { return livePids.contains(pid_t(k.dropFirst(8)) ?? -1) }
            if k.hasPrefix("orphan:") { return orphanPids.contains(pid_t(k.dropFirst(7)) ?? -1) }
            if k.hasPrefix("appram:") || k.hasPrefix("appcpu:") { return appKeys.contains(String(k.dropFirst(7))) }
            return true
        }

        // Memoria del sistema (el "valor" es la presión usada: crece cuando baja la libre).
        let systemLow = snap.freePercent < Config.systemFreeMinPercent
        if systemLow {
            let consumers = snap.sessions.prefix(2).map { (name: sessionLabel($0), bytes: $0.bytes) }
                + snap.apps.prefix(2).map { (name: $0.name, bytes: $0.bytes) }
            alert(key: "system", value: Double(100 - snap.freePercent),
                  text: systemLowText(freePercent: snap.freePercent, consumers: consumers), now: now)
            if autoKillSaturating, pendingKill == nil, !pauseActive(until: pausedUntil, now: now),
               let o = snap.orphans.first(where: { $0.bytes > Config.orphanBytes && !closedAttempted.contains($0.pid) }) {
                scheduleSaturatingKill(o)
            }
        }

        updateUI(snap, alerting: anyOver || systemLow || orphanOver || appOver)
        schedule(Config.pollActive)
        checkForUpdate(force: false)
    }

    /// SIGTERM al huérfano y sus descendientes (hijos primero), tras reverificar con un snapshot nuevo.
    private func close(_ o: OrphanProc) {
        guard let fresh = takeSnapshot().orphans.first(where: { $0.pid == o.pid }), parentPid(o.pid) == 1 else { return }
        for pid in fresh.tree.reversed() { kill(pid, SIGTERM) }
        notifier.send("Cerrado huérfano \(fresh.name) (\(formatBytes(fresh.bytes)), pid \(fresh.pid))")
    }

    /// Devuelve true si la alerta realmente se disparó (no pausa, no enfriamiento).
    @discardableResult
    private func alert(key: String, value: Double, text: String, now: Date) -> Bool {
        guard !pauseActive(until: pausedUntil, now: now) else { return false }
        if let last = lastAlert[key] {
            let cooled = now.timeIntervalSince(last.date) >= Config.cooldown
            let grew = value > last.value * Config.regrowthFactor
            guard cooled || grew else { return false }
        }
        lastAlert[key] = (now, value)
        notifier.send(text)
        return true
    }

    @objc private func toggleAutoClose() { autoClose.toggle() }

    /// Edita solo el texto de `env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` en ~/.claude/settings.json; no escribe si no se puede verificar.
    @objc private func setAutoCompact(_ sender: NSMenuItem) {
        let data = FileManager.default.contents(atPath: claudeSettingsPath)
        let text = data.map { String(data: $0, encoding: .utf8) } ?? ""
        guard let text, let out = verifiedAutoCompactEdit(text: text, pct: sender.representedObject as? Int) else {
            notifier.send("No se pudo editar ~/.claude/settings.json; cámbialo a mano")
            return
        }
        if out != text {
            do { try writeClaudeSettings(text: out) } catch {
                notifier.send("No se pudo escribir ~/.claude/settings.json: \(error.localizedDescription)")
                return
            }
        }
        if let p = panel { fillPanel(p) }
    }

    /// Avisa y cierra el huérfano tras `saturatingKillDelay` salvo que el usuario cancele desde el menú.
    private func scheduleSaturatingKill(_ o: OrphanProc) {
        closedAttempted.insert(o.pid)
        notifier.send("Memoria baja: Guachiman cerrará \(o.name) (pid \(o.pid)) en \(Int(Config.saturatingKillDelay)) s. Cancélalo en el menú.")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingKill = nil
            let snap = takeSnapshot()
            let bytes = snap.orphans.first(where: { $0.pid == o.pid })?.bytes
            guard shouldProceedSaturatingKill(freePercent: snap.freePercent, orphanBytes: bytes) else {
                let why = snap.freePercent >= Config.systemFreeMinPercent
                    ? "la memoria se recuperó" : "ya no supera \(Config.orphanBytes / 1_048_576) MB"
                self.notifier.send("Cierre de \(o.name) cancelado: \(why)")
                return
            }
            self.close(o)
        }
        pendingKill = (o.pid, o.name, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.saturatingKillDelay, execute: work)
    }

    @objc private func cancelPendingKill() {
        pendingKill?.work.cancel()
        pendingKill = nil
    }

    @objc private func toggleAutoKillSaturating() { autoKillSaturating.toggle() }

    @objc private func togglePause() {
        if pauseActive(until: pausedUntil, now: Date()) {
            pausedUntil = nil
        } else {
            pausedUntil = Date().addingTimeInterval(Config.pauseDuration)
            cancelPendingKill()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try? FileManager.default.removeItem(at: agentURL)
        } else if let exe = Bundle.main.executablePath {
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: launchAgentPlist(executable: exe), format: .xml, options: 0) {
                try? data.write(to: agentURL)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { stopRelay(wait: true) }

    @objc private func quit() {
        stopRelay(wait: true)
        exit(0)
    }

    /// Detiene el relay y vacía las alertas para que el próximo ciclo empiece limpio.
    private func stopRelay(wait: Bool) {
        runRelay("stop", wait: wait)
        truncateAlerts()
        relayRunning = false
        relayQuietSince = nil
    }

    /// Arranca el relay bajo demanda (antes de escribir una alerta); no relanza mientras esté arrancando o corriendo.
    private func startRelayIfNeeded() {
        guard aiEnabled, !aiLoginFailed, !relayRunning, claudeBinary() != nil else { return }
        relayRunning = true
        relayQuietSince = nil
        runRelay(nil, wait: false)
    }

    /// Con la IA activa, comprueba que Claude Code tenga sesión (no arranca nada). Devuelve false si falta.
    private func checkAILogin() -> Bool {
        guard aiEnabled, let claude = claudeBinary() else { return true }
        aiLoginFailed = !claudeLoggedIn(claude)
        return !aiLoginFailed
    }

    @objc private func toggleAI(_ sender: NSButton) {
        aiEnabled.toggle()
        if aiEnabled {
            if !checkAILogin() { notifier.send(Config.loginText) }
        } else {
            aiLoginFailed = false
            stopRelay(wait: false)
        }
        if let p = panel { fillPanel(p) }
    }   // status 0: KeepAlive { SuccessfulExit = false } no relanza

    private func toggle(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func updateUI(_ snap: Snapshot, alerting: Bool) {
        lastSnap = snap
        if let p = panel { fillPanel(p) }   // el panel abierto se refresca con cada sondeo
        if CommandLine.arguments.contains("--show-panel"), !debugPanelShown {   // solo para verificar
            debugPanelShown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.closePanel() }
            }
        }
        if let button = statusItem.button {
            // Ícono propio de 18 pt de alto; si no está en el bundle, usa el SF Symbol.
            let base: NSImage?
            if let custom = Bundle.main.image(forResource: "MenuBarIcon") {
                let ratio = custom.size.height > 0 ? custom.size.width / custom.size.height : 1
                custom.size = NSSize(width: 18 * ratio, height: 18)
                base = custom
            } else {
                base = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Guachiman")
            }
            base?.isTemplate = true
            if alerting {
                // Un bitmap no acepta paletas de SF Symbols: se pinta una copia roja no plantilla.
                let image = base.map { src -> NSImage in
                    let red = NSImage(size: src.size, flipped: false) { rect in
                        src.draw(in: rect)
                        NSColor.systemRed.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    red.isTemplate = false
                    return red
                }
                button.image = image
                button.alphaValue = 1
            } else {
                button.image = base
                button.alphaValue = snap.sessions.isEmpty ? 0.4 : 1
            }
        }
    }

    // MARK: Panel isla (se crea al abrir, se libera por completo al cerrar)

    private func nsColor(_ c: RowColor) -> NSColor {
        switch c {
        case .green: return Pal.primary
        case .yellow: return .systemYellow
        case .red: return Pal.destructive
        case .gray: return Pal.muted
        }
    }

    @objc private func togglePanel() { panel == nil ? openPanel() : closePanel() }

    private func openPanel() {
        guard panel == nil, statusItem.button?.window != nil else { return }
        let p = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.appearance = NSAppearance(named: .darkAqua)
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        if aiEnabled, aiLoginFailed { _ = checkAILogin() }   // reintento solo al abrir el panel
        refreshUsage()
        fillPanel(p)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
            guard let self, let p = self.panel, !self.menuOpen else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.closePanel(); return nil }   // Esc
            } else if e.window !== p, e.window !== self.statusItem.button?.window {
                self.closePanel()
            }
            return e
        }
    }

    /// Consulta los límites si la caché venció (5 min) y redibuja el panel si sigue abierto al terminar.
    private func refreshUsage() {
        guard claudeBinary() != nil, !usageFetching,
              usageFetchedAt.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        usageFetching = true
        fetchClaudeUsage { [weak self] limits in
            guard let self else { return }
            self.usageFetching = false
            self.usageLimits = limits
            self.usageFetchedAt = Date()
            if let p = self.panel { self.fillPanel(p) }
        }
    }

    private func closePanel() {
        guard let p = panel else { return }
        panel = nil
        rowTargets = []
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }, completionHandler: {
            p.orderOut(nil)
            p.contentView = nil
        })
    }

    /// Reconstruye el contenido a partir del último snapshot y recoloca el panel bajo el ícono.
    private func fillPanel(_ p: IslandPanel) {
        let snap = lastSnap ?? Snapshot(sessions: [], orphans: [], apps: [], freePercent: 100)
        let W: CGFloat = 300, pad: CGFloat = 6, iw = W - 2 * pad, rowH = PanelRow.height
        let limit = UInt64(Double(memory) * Config.sessionFraction)
        let sessions = Array(snap.sessions.prefix(8))
        let orphans = Array(snap.orphans.prefix(4))
        let apps = Array(snap.apps.prefix(5))
        let notice = aiEnabled && aiLoginFailed

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 100))
        root.wantsLayer = true
        root.layer?.backgroundColor = Pal.popover.cgColor
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 0.5
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        var y = pad

        // Cabecera: dos medidores y los botones IA / ajustes.
        let btnW: CGFloat = 22 * 2 + 2
        let meterW = (iw - 16 - btnW - 24) / 2
        func meter(_ x: CGFloat, _ label: String, _ value: String, _ fraction: Double, _ a11y: String) {
            root.addSubview(panelLabel(label, size: 11, color: Pal.muted, frame: NSRect(x: x, y: y + 8, width: meterW - 30, height: 14)))
            root.addSubview(panelLabel(value, size: 12, weight: .semibold, mono: true, align: .right,
                                       frame: NSRect(x: x + meterW - 30, y: y + 8, width: 30, height: 14)))
            let track = NSView(frame: NSRect(x: x, y: y + 8 + 14 + 5, width: meterW, height: 4))
            track.wantsLayer = true
            track.layer?.backgroundColor = Pal.accent.cgColor
            track.layer?.cornerRadius = 2
            track.setAccessibilityElement(true)
            track.setAccessibilityRole(.image)
            track.setAccessibilityLabel(a11y)
            // Calor: el degradado ocupa todo el ancho y la barra solo deja ver hasta el uso actual.
            let bar = NSView(frame: NSRect(x: 0, y: 0, width: meterW * CGFloat(max(0, min(1, fraction))), height: 4))
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 2
            bar.layer?.masksToBounds = true
            let heat = CAGradientLayer()
            heat.frame = CGRect(x: 0, y: 0, width: meterW, height: 4)
            heat.startPoint = CGPoint(x: 0, y: 0.5)
            heat.endPoint = CGPoint(x: 1, y: 0.5)
            heat.colors = [Pal.primary.cgColor, NSColor.systemYellow.cgColor, Pal.destructive.cgColor]
            heat.locations = [0.3, 0.6, 0.85]
            bar.layer?.addSublayer(heat)
            track.addSubview(bar)
            root.addSubview(track)
        }
        let usedRAM = 100 - snap.freePercent
        meter(pad + 8, "RAM", "\(usedRAM)%", Double(usedRAM) / 100, "RAM en uso \(usedRAM) %")
        meter(pad + 8 + meterW + 12, "CPU", cpuTotal.map { "\(Int($0.rounded()))%" } ?? "—", (cpuTotal ?? 0) / 100,
              cpuTotal.map { "CPU \(Int($0.rounded())) %" } ?? "CPU no disponible")

        let bx = pad + iw - 8 - btnW
        let by = y + 8 + (23 - 22) / 2
        let ai = HoverButton(frame: NSRect(x: bx, y: by, width: 22, height: 22))
        let hasClaude = claudeBinary() != nil
        let aiColor: NSColor = !hasClaude || !aiEnabled ? Pal.muted.withAlphaComponent(0.5)
            : (aiLoginFailed ? .systemYellow : Pal.foreground)
        ai.attributedTitle = NSAttributedString(string: "IA", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: aiColor])
        ai.isBordered = false
        ai.wantsLayer = true
        ai.layer?.cornerRadius = 5
        ai.isEnabled = hasClaude
        ai.toolTip = !hasClaude ? "Claude Code no está instalado"
            : (notice ? Config.loginText : "IA: avisar a la sesión de Claude dueña (enlace con Haiku)")
        ai.setAccessibilityLabel("IA: avisar a la sesión de Claude dueña (enlace con Haiku)")
        ai.target = self
        ai.action = #selector(toggleAI(_:))
        root.addSubview(ai)
        let gear = HoverButton(frame: NSRect(x: bx + 24, y: by, width: 22, height: 22))
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        gear.imagePosition = .imageOnly
        gear.isBordered = false
        gear.wantsLayer = true
        gear.layer?.cornerRadius = 5
        gear.contentTintColor = Pal.muted
        gear.toolTip = "Ajustes"
        gear.setAccessibilityLabel("Ajustes")
        gear.target = self
        gear.action = #selector(showSettings(_:))
        root.addSubview(gear)
        y += 8 + 23 + 10 + 2

        if notice {
            let l = NSTextField(wrappingLabelWithString: Config.loginText)
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = .systemYellow
            l.frame = NSRect(x: pad + 8, y: y, width: iw - 16, height: 30)
            root.addSubview(l)
            y += 30 + 2
        }

        func divider(topMargin: CGFloat) {
            y += topMargin
            let d = NSView(frame: NSRect(x: pad + 8, y: y, width: iw - 16, height: 0.5))
            d.wantsLayer = true
            d.layer?.backgroundColor = Pal.border.cgColor
            root.addSubview(d)
            y += 0.5 + 2
        }
        func section(_ title: String, total: String? = nil) {
            root.addSubview(panelLabel(title, size: 11, weight: .semibold, color: Pal.muted,
                                       frame: NSRect(x: pad + 8, y: y + 8, width: iw - 16 - 80, height: 14)))
            if let total {
                root.addSubview(panelLabel(total, size: 11, mono: true, color: Pal.muted, align: .right,
                                           frame: NSRect(x: pad + iw - 8 - 80, y: y + 8, width: 80, height: 14)))
            }
            y += 8 + 14 + 4 + 2
        }

        rowTargets = []
        func addRow(_ text: String, _ bytes: UInt64, _ cpu: Double, _ color: RowColor, _ t: KillTarget, tip: String,
                    ctx: (text: String, color: NSColor)? = nil) {
            var tag: Int?
            if !t.pids.isEmpty, !t.pids.contains(getpid()) {   // nunca ofrece cerrar a Guachiman
                rowTargets.append(t)
                tag = rowTargets.count - 1
            }
            let r = PanelRow(width: iw, text: text, memory: formatBytes(bytes), cpu: "\(Int(cpu.rounded()))%",
                             color: nsColor(color), stopTag: tag, stopLabel: "Cerrar \(t.name)", stopTip: tip,
                             target: self, action: #selector(stopClicked(_:)), ctx: ctx)
            r.frame.origin = NSPoint(x: pad, y: y)
            root.addSubview(r)
            y += rowH
        }

        if claudeBinary() != nil {
            divider(topMargin: 0)
            section("Uso de Claude")
            let limits = usageLimits ?? []
            if limits.isEmpty {
                root.addSubview(panelLabel(usageFetchedAt == nil ? "Cargando…" : "sin datos", size: 12.5, color: Pal.muted,
                                           frame: NSRect(x: pad + 8, y: y + 4, width: iw - 16, height: 16)))
                y += rowH
            }
            let now = Date()
            for u in limits {
                let tint: NSColor = u.severity == "normal" && u.percent < 90 ? Pal.primary
                    : (["critical", "exceeded", "danger", "error"].contains(u.severity) || u.percent >= 90 ? Pal.destructive : .systemYellow)
                let reset = u.resetsAt.map { " · " + usageResetText($0, now: now) } ?? ""
                root.addSubview(panelLabel(u.label, size: 12.5,
                                           frame: NSRect(x: pad + 8, y: y + 3, width: iw - 16 - 110, height: 16)))
                root.addSubview(panelLabel("\(u.percent)%\(reset)", size: 11, mono: true,
                                           color: u.severity == "normal" ? Pal.muted : tint, align: .right,
                                           frame: NSRect(x: pad + iw - 8 - 110, y: y + 3, width: 110, height: 16)))
                let track = NSView(frame: NSRect(x: pad + 8, y: y + 3 + 16 + 3, width: iw - 16, height: 4))
                track.wantsLayer = true
                track.layer?.backgroundColor = Pal.accent.cgColor
                track.layer?.cornerRadius = 2
                track.setAccessibilityElement(true)
                track.setAccessibilityRole(.image)
                track.setAccessibilityLabel("\(u.label) \(u.percent) %")
                let bar = NSView(frame: NSRect(x: 0, y: 0, width: (iw - 16) * CGFloat(max(0, min(100, u.percent))) / 100, height: 4))
                bar.wantsLayer = true
                bar.layer?.backgroundColor = tint.cgColor
                bar.layer?.cornerRadius = 2
                track.addSubview(bar)
                root.addSubview(track)
                y += 34
            }
        }

        divider(topMargin: claudeBinary() != nil ? 2 : 0)
        section("Sesiones de Claude", total: sessions.isEmpty ? nil : formatBytes(sessions.reduce(0) { $0 + $1.bytes }))
        if sessions.isEmpty {
            root.addSubview(panelLabel("Sin sesiones de Claude", size: 12.5, color: Pal.muted,
                                       frame: NSRect(x: pad + 8, y: y + 4, width: iw - 16, height: 16)))
            y += rowH
        }
        for s in sessions {
            let c = rowColor(bytes: s.bytes, cpu: s.cpu, ramLimit: limit, cpuLimit: Config.appCpuPercent,
                             idleFor: lastIdle["session:\(s.pid)"] ?? 0)
            let title = sessionTitle(pid: s.pid).map(truncatedTitle)
            var ctx: (text: String, color: NSColor)?
            if let info = sessionContext(pid: s.pid) { ctx = (formatContextTokens(info.used), Pal.muted) }
            addRow(title ?? s.label, s.bytes, s.cpu, c,
                   KillTarget(name: title ?? "Claude (\(s.label))", bytes: s.bytes, pids: s.tree, appPath: nil, expandTree: false),
                   tip: "Detener", ctx: ctx)
        }

        divider(topMargin: 2)
        section("Apps que más consumen")
        for a in apps {
            let c = rowColor(bytes: a.bytes, cpu: a.cpu, ramLimit: limit, cpuLimit: Config.appCpuPercent,
                             idleFor: lastIdle[a.key] ?? 0)
            let single = a.key.hasPrefix("pid:")
            addRow(a.name, a.bytes, a.cpu, c,
                   KillTarget(name: a.name, bytes: a.bytes, pids: a.pids, appPath: single ? nil : a.key, expandTree: single),
                   tip: "Cerrar app")
        }
        if !orphans.isEmpty {
            divider(topMargin: 2)
            section("Huérfanos")
            for o in orphans {
                let c = rowColor(bytes: o.bytes, cpu: o.cpu, ramLimit: Config.orphanBytes, cpuLimit: nil,
                                 idleFor: lastIdle["orphan:\(o.pid)"] ?? 0)
                addRow(o.name, o.bytes, o.cpu, c,
                       KillTarget(name: o.name, bytes: o.bytes, pids: o.tree, appPath: nil, expandTree: false),
                       tip: "Detener")
            }
        }

        let H = y + 4 + pad
        root.frame.size = NSSize(width: W, height: H)
        p.contentView = root
        // Centrado bajo el ícono y recortado a la zona visible de la pantalla.
        if let button = statusItem.button, let win = button.window {
            let r = win.convertToScreen(button.convert(button.bounds, to: nil))
            let vf = (win.screen ?? NSScreen.main)?.visibleFrame ?? r
            let x = max(vf.minX + 8, min(r.midX - W / 2, vf.maxX - W - 8))
            p.setFrame(NSRect(x: x, y: max(vf.minY, r.minY - 6 - H), width: W, height: H), display: true)
            p.invalidateShadow()
        }
    }

    @objc private func showSettings(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if pauseActive(until: pausedUntil, now: Date()), let until = pausedUntil {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            menu.addItem(toggle("Reanudar (pausado hasta \(f.string(from: until)))", #selector(togglePause), on: false))
        } else {
            menu.addItem(toggle("Pausar 1 h", #selector(togglePause), on: false))
        }
        menu.addItem(toggle("Cerrar huérfanos automáticamente", #selector(toggleAutoClose), on: autoClose))
        menu.addItem(toggle("Cerrar procesos que saturen el PC", #selector(toggleAutoKillSaturating), on: autoKillSaturating))
        if let pending = pendingKill {
            menu.addItem(NSMenuItem(title: "Cancelar cierre de \(pending.name) (pid \(pending.pid))",
                                    action: #selector(cancelPendingKill), keyEquivalent: ""))
        }
        let acItem = NSMenuItem(title: "Auto-compact de Claude", action: nil, keyEquivalent: "")
        let acMenu = NSMenu()
        let acCurrent = readClaudeSettings().flatMap(autoCompactPct)
        for pct in [nil, 50, 60, 70, 80] as [Int?] {
            let it = NSMenuItem(title: pct.map { "\($0) %" } ?? "Por defecto de Claude", action: #selector(setAutoCompact(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = pct
            it.state = pct == acCurrent ? .on : .off
            acMenu.addItem(it)
        }
        acItem.submenu = acMenu
        menu.addItem(acItem)
        menu.addItem(toggle("Iniciar al encender", #selector(toggleLaunchAtLogin),
                            on: FileManager.default.fileExists(atPath: agentURL.path)))
        if !notifier.isAuthorized {
            let item = NSMenuItem(title: "Activar notificaciones", action: #selector(openNotificationSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let updateItem = NSMenuItem(title: availableVersion.map { "Actualizar a \($0)" } ?? "Actualizar",
                                    action: #selector(runUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = !updating
        if availableVersion != nil {
            let dot = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: r).fill()
                return true
            }
            updateItem.image = dot
        }
        menu.addItem(updateItem)
        let checkItem = NSMenuItem(title: "Buscar actualizaciones", action: #selector(checkUpdateClicked), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
        let uninstallItem = NSMenuItem(title: "Desinstalar", action: #selector(confirmUninstall), keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)
        let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        menuOpen = false
    }

    private var updating = false

    @objc private func checkUpdateClicked() { checkForUpdate(force: true) }

    @objc private func runUpdate() {
        guard !updating, let script = Bundle.main.resourcePath.map({ $0 + "/update.sh" }),
              FileManager.default.fileExists(atPath: script) else { return }
        updating = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let last = out.split(separator: "\n").last.map(String.init) ?? "No se pudo actualizar"
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.updating = false
                if status == 0 || status == 10 { self.availableVersion = nil }
                if status == 0 { return }
                let alert = NSAlert()
                if status == 10 {
                    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                    alert.messageText = "Ya tienes la última versión (\(v))"
                } else {
                    alert.messageText = last
                }
                alert.addButton(withTitle: "OK")
                let offerReleases = status == 2 && self.availableVersion != nil
                if offerReleases { alert.addButton(withTitle: "Abrir releases") }
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn, offerReleases,
                   let url = URL(string: Config.releasesPageURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        guard (try? p.run()) != nil else { updating = false; return }
    }

    @objc private func confirmUninstall() {
        closePanel()
        DispatchQueue.main.async { [weak self] in self?.runUninstall() }
    }

    private func runUninstall() {
        let alert = NSAlert()
        alert.messageText = "¿Desinstalar Guachiman?"
        alert.informativeText = "Se quitarán la app, la instalación de Homebrew, la copia en ~/Applications, los ajustes y los datos. Esta acción no se puede deshacer."
        alert.alertStyle = .warning
        let go = alert.addButton(withTitle: "Desinstalar")
        if #available(macOS 11.0, *) { go.hasDestructiveAction = true }
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let script = Bundle.main.resourcePath.map({ $0 + "/uninstall.sh" }),
              FileManager.default.fileExists(atPath: script) else { return }
        // Desacoplado en su propia sesión (setsid vía perl) para que launchd no lo mate al detener el servicio.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use POSIX; POSIX::setsid(); exec @ARGV", "/bin/bash", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        exit(0)
    }

    @objc private func stopClicked(_ sender: NSButton) {
        guard rowTargets.indices.contains(sender.tag) else { return }
        let t = rowTargets[sender.tag]
        closePanel()
        DispatchQueue.main.async { [weak self] in self?.confirmClose(t) }
    }

    private func confirmClose(_ t: KillTarget) {
        let live = t.pids.filter(alive)
        guard !live.isEmpty else { return }
        let shown = live.prefix(6).map(String.init).joined(separator: ", ")
        let pidText = (live.count == 1 ? "pid " : "pids ") + shown + (live.count > 6 ? " y \(live.count - 6) más" : "")
        let alert = NSAlert()
        alert.messageText = "¿Cerrar \(t.name)?"
        alert.informativeText = "\(formatBytes(t.bytes)) · \(pidText)"
        alert.addButton(withTitle: "Cerrar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        terminate(t)
    }

    private func terminate(_ t: KillTarget) {
        var apps: [NSRunningApplication] = []
        if let path = t.appPath {
            let want = path.hasSuffix("/") ? String(path.dropLast()) : path
            apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == want }
        }
        let targets: [pid_t]   // en el orden en que se señalan (hijos primero)
        if !apps.isEmpty {
            apps.forEach { $0.terminate() }
            targets = apps.map { $0.processIdentifier }
        } else {
            let tree = t.expandTree ? t.pids.flatMap { liveTree($0) } : t.pids
            targets = t.appPath == nil ? tree.reversed() : tree
            for pid in targets where alive(pid) { kill(pid, SIGTERM) }
        }
        let closing = apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let left = targets.filter(alive)
            guard !left.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "\(t.name) sigue abierto. ¿Forzar cierre?"
            alert.addButton(withTitle: "Forzar")
            alert.addButton(withTitle: "Cancelar")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !closing.isEmpty {
                closing.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            } else {
                for pid in left where alive(pid) { kill(pid, SIGKILL) }
            }
        }
    }
}

// MARK: - Copia en ~/Applications

let showPanelNotification = "io.github.guachiman.showPanel"

/// Homebrew deja la app en Cellar, que Spotlight/Launchpad no indexan: se copia a ~/Applications.
/// Solo reemplaza un bundle propio (mismo identificador) cuya versión difiere; los errores se ignoran.
func installCopyInApplications() {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    let target = dir.appendingPathComponent("Guachiman.app")
    let src = Bundle.main.bundleURL
    guard src.pathExtension == "app", src.standardizedFileURL.path != target.standardizedFileURL.path else { return }
    func info(_ url: URL) -> [String: Any]? {
        NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }
    let mine = Bundle.main.infoDictionary
    if fm.fileExists(atPath: target.path) {
        guard let theirs = info(target),
              theirs["CFBundleIdentifier"] as? String == mine?["CFBundleIdentifier"] as? String else { return }
        if theirs["CFBundleVersion"] as? String == mine?["CFBundleVersion"] as? String { return }
    }
    do {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: src, to: target)
        // Homebrew borra las versiones viejas del Cellar, pero LaunchServices conserva sus registros y las notificaciones salen con ícono en blanco.
        let snippet = #"""
        LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
        "$LS" -dump | sed -n 's/^path: *\(.*Guachiman\.app\) (0x.*/\1/p' | sort -u | while read -r p; do [ -d "$p" ] || "$LS" -u "$p"; done
        "$LS" -f "$HOME/Applications/Guachiman.app"
        killall usernoted NotificationCenter 2>/dev/null
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", snippet]
        p.standardOutput = nil
        p.standardError = nil
        try? p.run()
    } catch {
        FileHandle.standardError.write(Data("guachiman: no se pudo copiar a ~/Applications: \(error)\n".utf8))
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--once") {
    runOnce()
    exit(0)
}

// Desde el symlink de Homebrew (bin/guachiman) Bundle.main no es el .app: se resuelve el ejecutable real.
let cliResources = Bundle.main.executableURL!.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").path

if CommandLine.arguments.contains("--uninstall") {
    guard let script = Optional(cliResources + "/uninstall.sh"),
          FileManager.default.fileExists(atPath: script) else {
        FileHandle.standardError.write(Data("guachiman: no se encontró uninstall.sh en el bundle\n".utf8))
        exit(1)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script]
    guard (try? p.run()) != nil else { exit(1) }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

if CommandLine.arguments.contains("--update") {
    guard let script = Optional(cliResources + "/update.sh"),
          FileManager.default.fileExists(atPath: script) else {
        FileHandle.standardError.write(Data("guachiman: no se encontró update.sh en el bundle\n".utf8))
        exit(1)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script]
    guard (try? p.run()) != nil else { exit(1) }
    p.waitUntilExit()
    exit(p.terminationStatus)
}

if CommandLine.arguments.contains("--check-update") {
    let sem = DispatchSemaphore(value: 0)
    var latest: String?
    fetchLatestVersion { latest = $0; sem.signal() }
    guard sem.wait(timeout: .now() + 12) == .success, let v = latest else {
        FileHandle.standardError.write(Data("guachiman: no se pudo comprobar la versión\n".utf8))
        exit(1)
    }
    let cur = installedVersion
    print(isNewerVersion(v, than: cur) ? "Última versión: \(v) (instalada: \(cur))" : "Al día (\(cur))")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

// Instancia única: si ya corre otra app con el mismo bundle id, pedirle que abra su panel y salir.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .contains(where: { $0.processIdentifier != getpid() }) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(showPanelNotification), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

installCopyInApplications()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
