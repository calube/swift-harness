// The git the repository scripts launch. `/usr/bin/git` is an xcrun shim, byte-identical to
// `/usr/bin/swift`: it picks the tool to launch from a lookup cache in the user's temp dir that
// every concurrent git, swift and xcrun launch on the machine reads and rewrites, and under a
// parallel run that lookup has launched swift for git. The selected developer dir's own
// `usr/bin/git` is the tool the shim would pick, without the lookup.
import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

function developerDirectory() {
  if (process.env.DEVELOPER_DIR) return process.env.DEVELOPER_DIR
  try {
    return execFileSync('/usr/bin/xcode-select', ['-p'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return ''
  }
}

// PATH's `git` where no developer dir holds one (a machine without Xcode or its command line
// tools has no shim to skip either).
export const gitPath = (() => {
  const directory = developerDirectory()
  const git = directory && join(directory, 'usr/bin/git')
  return git && existsSync(git) ? git : 'git'
})()
