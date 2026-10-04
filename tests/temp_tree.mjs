// Removes a test's temporary directory together with the lock files SwiftPM left for every
// package in it. SwiftPM locks a package's scratch directory through a file in the temp
// directory named after the scratch path with every `/` made `_`, and never removes it, so each
// throwaway package otherwise leaves 1 to 3 files behind in the directory every tool shares.
import { existsSync, lstatSync, readdirSync, realpathSync, rmSync, unlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const skipped = new Set(['.build', '.git', '.swiftpm', 'node_modules'])

function packages(directory, found = []) {
  let names
  try {
    names = readdirSync(directory)
  } catch {
    return found
  }
  for (const name of names) {
    if (name === 'Package.swift') found.push(directory)
    else if (!skipped.has(name)) {
      const child = join(directory, name)
      if (lstatSync(child, { throwIfNoEntry: false })?.isDirectory()) packages(child, found)
    }
  }
  return found
}

export function removeTempTree(directory, lockDirectory = tmpdir()) {
  if (existsSync(directory)) {
    for (const pkg of packages(directory)) {
      const stem = join(realpathSync(pkg), '.build').replaceAll('/', '_')
      for (const suffix of ['', '_workspace-state.json', '_Package.resolved']) {
        try {
          unlinkSync(join(lockDirectory, `${stem}${suffix}.lock`))
        } catch {
          // Most packages never ran SwiftPM, so most of these names were never made.
        }
      }
    }
  }
  rmSync(directory, { recursive: true, force: true })
}
