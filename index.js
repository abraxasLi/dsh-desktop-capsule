/**
 * Desktop capsule — host half.
 *
 * Watches live agents and mirrors their state into a small JSON status file
 * that a separate always-on-top capsule process renders on the desktop.
 * The capsule process is spawned once per host and terminated with the plugin.
 */
import { spawn } from 'node:child_process'
import { mkdirSync, writeFileSync, renameSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { homedir } from 'node:os'

const HERE = dirname(fileURLToPath(import.meta.url))

const HEARTBEAT_MS = 2000
const MAX_SESSIONS = 6
const MAX_RESTARTS = 3

/** Directory shared with the capsule process. */
function statusDirectory() {
  const home = typeof process.env.DSH_HOME === 'string' && process.env.DSH_HOME.trim() !== ''
    ? process.env.DSH_HOME
    : join(homedir(), '.dsh')
  return join(home, 'desktop-capsule')
}

/**
 * Mirror of the agent state the capsule draws.
 * @param {import('@deepseek-ai/cordis').Context} ctx - host context of this plugin.
 */
export function apply(ctx) {
  const dir = statusDirectory()
  const statusPath = join(dir, 'status.json')
  const logPath = join(dir, 'plugin.log')
  try {
    mkdirSync(dir, { recursive: true })
  } catch {
    // A missing directory is reported through the log write below.
  }

  /** @type {Map<string, object>} */
  const sessions = new Map()
  /** @type {Array<() => void>} */
  const disposers = []
  /** @type {import('node:child_process').ChildProcess | null} */
  let child = null
  let heartbeat = null
  let restartTimer = null
  let restarts = 0
  let disposed = false

  const log = (message) => {
    try {
      writeFileSync(logPath, `[${new Date().toISOString()}] ${message}\n`, { flag: 'a' })
    } catch {
      // Logging must never break the host.
    }
  }

  /** Sessions owned by a subagent are noise for a human-facing status line. */
  const isHumanSession = (session) => {
    if (session === undefined || session === null) return false
    const header = session.header
    return header === undefined || header === null || header.origin !== 'subagent'
  }

  const entryOf = (sessionId) => {
    let entry = sessions.get(sessionId)
    if (entry === undefined) {
      entry = {
        sessionId,
        state: 'idle',
        since: Date.now(),
        turn: 0,
        detail: '',
        error: '',
        durationMs: 0,
        busySince: 0,
        doneAt: 0,
      }
      sessions.set(sessionId, entry)
    }
    return entry
  }

  const entryForAgent = (agent) => {
    if (agent === undefined || agent === null) return null
    const session = agent.session
    if (!isHumanSession(session)) return null
    return entryOf(session.id)
  }

  /**
   * Seed and correct state from the live registry, so a plugin reload in the
   * middle of a turn does not sit on a stale `idle` entry until the next
   * transition event arrives.
   */
  const reconcile = () => {
    let registry = null
    try {
      registry = ctx.get('agents')
    } catch {
      return
    }
    if (registry === null || registry === undefined || typeof registry.list !== 'function') return
    let agents
    try {
      agents = registry.list()
    } catch {
      return
    }
    for (const agent of agents) {
      if (!isHumanSession(agent.session)) continue
      const existing = sessions.get(agent.session.id)
      const now = Date.now()
      if (agent.status === 'running') {
        const entry = existing ?? entryOf(agent.session.id)
        if (entry.state === 'idle' || entry.state === 'done' || entry.state === 'error') {
          entry.state = 'running'
          entry.since = now
          entry.busySince = entry.busySince > 0 ? entry.busySince : now
          entry.error = ''
          entry.doneAt = 0
        }
      } else if (existing !== undefined && existing.state === 'running') {
        existing.state = 'done'
        existing.doneAt = now
        existing.durationMs = existing.busySince > 0 ? now - existing.busySince : 0
        existing.since = now
        existing.busySince = 0
      }
    }
  }

  const flush = () => {
    if (disposed) return
    reconcile()
    const ordered = [...sessions.values()]
      .sort((left, right) => right.since - left.since)
      .slice(0, MAX_SESSIONS)
    const payload = {
      v: 1,
      updatedAt: Date.now(),
      pid: process.pid,
      sessions: ordered.map(entry => ({
        sessionId: entry.sessionId,
        state: entry.state,
        since: entry.since,
        turn: entry.turn,
        detail: entry.detail,
        error: entry.error,
        durationMs: entry.durationMs,
        doneAt: entry.doneAt,
      })),
    }
    try {
      const temporary = `${statusPath}.tmp`
      writeFileSync(temporary, JSON.stringify(payload), 'utf8')
      renameSync(temporary, statusPath)
    } catch (error) {
      log(`status write failed: ${String(error)}`)
    }
  }

  const listen = (event, handler, options) => {
    const registration = options ?? { global: true }
    try {
      const dispose = ctx.on(event, handler, registration)
      if (typeof dispose === 'function') disposers.push(dispose)
    } catch (error) {
      try {
        const dispose = ctx.on(event, handler)
        if (typeof dispose === 'function') disposers.push(dispose)
      } catch (fallbackError) {
        log(`cannot listen on ${event}: ${String(fallbackError)}`)
      }
    }
  }

  // ---- agent lifecycle -------------------------------------------------
  listen('agent/created', ({ agent }) => {
    const entry = entryForAgent(agent)
    if (entry === null) return
    entry.state = 'idle'
    entry.since = Date.now()
    flush()
  })

  listen('agent/status', ({ agent, status }) => {
    const entry = entryForAgent(agent)
    if (entry === null) return
    const now = Date.now()
    if (status === 'running') {
      entry.state = 'running'
      entry.since = now
      entry.busySince = now
      entry.detail = ''
      entry.error = ''
      entry.doneAt = 0
    } else if (entry.state === 'running' || entry.state === 'approval' || entry.state === 'question') {
      entry.state = 'done'
      entry.doneAt = now
      entry.durationMs = entry.busySince > 0 ? now - entry.busySince : 0
      entry.since = now
      entry.busySince = 0
    }
    flush()
  })

  listen('agent/error', ({ agent, error }) => {
    const entry = entryForAgent(agent)
    if (entry === null) return
    const text = error instanceof Error ? error.message : String(error ?? 'unknown error')
    entry.state = 'error'
    entry.since = Date.now()
    entry.error = text.slice(0, 160)
    entry.busySince = 0
    flush()
  })

  listen('agent/disposed', ({ agent }) => {
    const entry = entryForAgent(agent)
    if (entry === null) return
    sessions.delete(entry.sessionId)
    flush()
  })

  // ---- turn boundaries -------------------------------------------------
  listen('session/event', (session, event) => {
    if (!isHumanSession(session) || event === undefined || event === null) return
    const entry = entryOf(session.id)
    const now = Date.now()
    if (event.type === 'turn/start') {
      entry.turn = Number(event.data?.turn ?? entry.turn ?? 0)
      if (entry.busySince === 0) entry.busySince = now
      if (entry.state !== 'approval' && entry.state !== 'question') {
        entry.state = 'running'
        entry.since = now
        entry.error = ''
        entry.doneAt = 0
      }
      flush()
    } else if (event.type === 'turn/end') {
      if (entry.state !== 'error') {
        entry.state = 'done'
        entry.doneAt = now
        entry.durationMs = entry.busySince > 0 ? now - entry.busySince : 0
        entry.since = now
        entry.busySince = 0
      }
      flush()
    }
  })

  // ---- human waits -----------------------------------------------------
  const beginWait = (agent, state, detail) => {
    const entry = entryForAgent(agent)
    if (entry === null) return null
    entry.state = state
    entry.since = Date.now()
    entry.detail = detail
    flush()
    return entry
  }

  const endWait = (entry) => {
    if (entry === null || entry === undefined) return
    if (entry.state === 'approval' || entry.state === 'question') {
      entry.state = 'running'
      entry.since = Date.now()
      entry.detail = ''
    }
    flush()
  }

  listen('approval/request', async (request, next) => {
    const entry = beginWait(request?.agent, 'approval', String(request?.toolName ?? '操作'))
    try {
      return await next()
    } finally {
      endWait(entry)
    }
  })

  listen('user-questions/request', async (request, next) => {
    const questions = Array.isArray(request?.questions) ? request.questions.length : 1
    const entry = beginWait(
      request?.agent,
      'question',
      questions > 1 ? `${questions} 个问题` : '一个问题',
    )
    try {
      return await next()
    } finally {
      endWait(entry)
    }
  })

  // ---- capsule process -------------------------------------------------
  const powershellPath = () => {
    const root = process.env.SystemRoot ?? 'C:\\Windows'
    return join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  }

  const launch = () => {
    if (disposed || process.platform !== 'win32') return
    if (child !== null) return
    const scriptPath = join(HERE, 'capsule.ps1')
    const args = [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-Root', dir,
      '-TargetPid', String(process.pid),
    ]
    log(`launching capsule: ${args.join(' ')}`)
    try {
      child = spawn(powershellPath(), args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
      child.stdout?.on('data', (chunk) => log(`capsule stdout: ${String(chunk).trim().slice(0, 500)}`))
      child.stderr?.on('data', (chunk) => log(`capsule stderr: ${String(chunk).trim().slice(0, 1500)}`))
      child.on('error', (error) => {
        log(`capsule spawn failed: ${String(error)}`)
      })
      child.on('exit', (code) => {
        child = null
        if (disposed) return
        if (restarts >= MAX_RESTARTS) {
          log(`capsule exited (${String(code)}) and restart budget is spent`)
          return
        }
        restarts += 1
        log(`capsule exited (${String(code)}); restart ${String(restarts)}`)
        restartTimer = setTimeout(launch, 2500)
      })
      child.unref()
    } catch (error) {
      log(`cannot launch capsule: ${String(error)}`)
    }
  }

  const stopCapsule = () => {
    if (restartTimer !== null) {
      clearTimeout(restartTimer)
      restartTimer = null
    }
    if (child === null) return
    try {
      child.kill()
    } catch {
      // Best effort; the stale heartbeat stops an orphan.
    }
    child = null
  }

  ctx.effect(() => {
    return () => {
      disposed = true
      if (heartbeat !== null) clearInterval(heartbeat)
      for (const dispose of disposers) {
        try {
          dispose()
        } catch {
          // Unwinding listeners is best effort.
        }
      }
      stopCapsule()
    }
  })

  flush()
  launch()
  heartbeat = setInterval(flush, HEARTBEAT_MS)
  log(`started; status=${statusPath}; pid=${process.pid}`)
}
