// Drives a headless Chrome over the DevTools protocol so page tests can load a file, press keys,
// click, read DOM state and collect console errors. No browser library: Node 22's global WebSocket
// speaks the protocol directly.
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const CANDIDATES = [
  process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
].filter(Boolean)

/** The Chrome binary to drive, or null when none is installed. */
export function findChrome() {
  return CANDIDATES.find((path) => existsSync(path)) ?? null
}

const KEYS = {
  Tab: { code: 'Tab', windowsVirtualKeyCode: 9 },
  Enter: { code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' },
  Escape: { code: 'Escape', windowsVirtualKeyCode: 27 },
}

/**
 * Starts Chrome and opens one tab. Every command rejects once `deadlineMs` passes, so a hung
 * browser fails the test instead of outliving the script's timeout.
 */
export async function launch({ deadlineMs = 12000 } = {}) {
  const binary = findChrome()
  if (!binary) throw new Error('no Chrome binary found')
  const profile = mkdtempSync(join(tmpdir(), 'run-viewer-chrome-'))
  const chrome = spawn(binary, [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run',
    '--no-default-browser-check', '--disable-gpu', '--disable-extensions', '--allow-file-access-from-files',
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] })

  let closed = false
  const exited = new Promise((resolve) => chrome.once('exit', resolve))
  const removeProfile = () => {
    try { rmSync(profile, { recursive: true, force: true, maxRetries: 5 }) } catch {}
  }
  // Chrome writes its profile until it exits, so the profile goes only after the exit event.
  const close = async () => {
    if (closed) return
    closed = true
    clearTimeout(deadline)
    try { socket?.close() } catch {}
    chrome.kill('SIGKILL')
    await exited
    removeProfile()
  }
  process.once('exit', () => { if (!closed) { chrome.kill('SIGKILL'); removeProfile() } })

  const pending = new Map()
  let socket = null
  const fail = (error) => {
    for (const { reject } of pending.values()) reject(error)
    pending.clear()
    close()
  }
  const deadline = setTimeout(() => fail(new Error(`headless Chrome passed its ${deadlineMs} ms deadline`)), deadlineMs)

  const endpoint = await new Promise((resolve, reject) => {
    let text = ''
    chrome.stderr.setEncoding('utf8')
    chrome.stderr.on('data', (chunk) => {
      text += chunk
      const match = text.match(/DevTools listening on (ws:\/\/\S+)/)
      if (match) resolve(match[1])
    })
    chrome.once('exit', (code) => reject(new Error(`Chrome exited (${code}) before listening:\n${text}`)))
    chrome.once('error', reject)
  })

  socket = new WebSocket(endpoint)
  await new Promise((resolve, reject) => {
    socket.onopen = resolve
    socket.onerror = () => reject(new Error('could not connect to Chrome'))
  })

  let nextId = 1
  const listeners = []
  socket.onmessage = (message) => {
    const data = JSON.parse(message.data)
    if (data.id && pending.has(data.id)) {
      const { resolve, reject } = pending.get(data.id)
      pending.delete(data.id)
      if (data.error) reject(new Error(`${data.error.message} (${data.error.code})`))
      else resolve(data.result)
    } else if (data.method) {
      for (const listener of [...listeners]) listener(data)
    }
  }
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    if (closed) return reject(new Error('Chrome is closed'))
    const id = nextId++
    pending.set(id, { resolve, reject })
    socket.send(JSON.stringify({ id, method, params, sessionId }))
  })
  const once = (method, sessionId) => new Promise((resolve) => {
    const listener = (event) => {
      if (event.method !== method || event.sessionId !== sessionId) return
      listeners.splice(listeners.indexOf(listener), 1)
      resolve(event.params)
    }
    listeners.push(listener)
  })

  const { targetId } = await send('Target.createTarget', { url: 'about:blank' })
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true })
  const call = (method, params) => send(method, params, sessionId)
  const errors = []
  listeners.push((event) => {
    if (event.sessionId !== sessionId) return
    if (event.method === 'Runtime.exceptionThrown') {
      errors.push(event.params.exceptionDetails.exception?.description ?? event.params.exceptionDetails.text)
    } else if (event.method === 'Runtime.consoleAPICalled' && event.params.type === 'error') {
      errors.push(event.params.args.map((arg) => arg.value ?? arg.description).join(' '))
    } else if (event.method === 'Log.entryAdded' && event.params.entry.level === 'error') {
      errors.push(event.params.entry.text)
    }
  })
  await Promise.all([call('Page.enable'), call('Runtime.enable'), call('Log.enable')])

  const page = {
    errors,
    async viewport(width, height) {
      await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false })
    },
    async load(url) {
      errors.length = 0
      const loaded = once('Page.loadEventFired', sessionId)
      await call('Page.navigate', { url })
      await loaded
    },
    async evaluate(expression) {
      const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
      if (result.exceptionDetails) {
        throw new Error(result.exceptionDetails.exception?.description ?? result.exceptionDetails.text)
      }
      return result.result.value
    },
    async press(key) {
      const spec = KEYS[key]
      if (!spec) throw new Error(`no key spec for ${key}`)
      await call('Input.dispatchKeyEvent', { type: spec.text ? 'keyDown' : 'rawKeyDown', key, ...spec })
      await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code: spec.code, windowsVirtualKeyCode: spec.windowsVirtualKeyCode })
    },
    /** A PNG of the whole page, base64, for looking at a failure by eye. */
    async screenshot() {
      return (await call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })).data
    },
    async click(x, y) {
      for (const type of ['mousePressed', 'mouseReleased']) {
        await call('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 })
      }
    },
  }
  return { page, close }
}
