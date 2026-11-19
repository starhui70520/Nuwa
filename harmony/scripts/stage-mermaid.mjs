import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

// Last v11 release. Mermaid v11.16.1 fixed the upstream August 2026 renderer advisories.
const version = '11.17.2'
const integrity = 'V6K3C8EBdEsPFZXSKMJe6ppQOENxuHARr9GvHX4hh47lAbhMRD9qf4oEK7LoaRQxULMa80/qt5gHO73aCleBBg=='
const packageName = 'mermaid-' + version + '.tgz'
const tarball = new URL(packageName, 'https://registry.npmjs.org/mermaid/-/')
const cache = fileURLToPath(new URL('../.hvigor/mermaid/' + packageName, import.meta.url))
const resources = new URL('../entry/src/main/resources/rawfile/mermaid/', import.meta.url)

function verify(archive) {
  if (createHash('sha512').update(archive).digest('base64') !== integrity) {
    throw new Error('Mermaid archive does not match the pinned npm integrity value')
  }
}

async function prepareArchive() {
  try {
    const archive = await readFile(cache)
    verify(archive)
    return
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }

  const response = await fetch(tarball, { redirect: 'error', signal: AbortSignal.timeout(120_000) })
  if (!response.ok) throw new Error('Mermaid download failed (HTTP ' + response.status + ')')
  const archive = Buffer.from(await response.arrayBuffer())
  verify(archive)
  await mkdir(dirname(cache), { recursive: true })
  await writeFile(cache, archive)
}

function readMember(member) {
  return execFileSync('tar', ['-xOzf', cache, 'package/' + member], { maxBuffer: 16 * 1024 * 1024 })
}

await prepareArchive()
const renderer = readMember('dist/mermaid.min.js')
const license = readMember('LICENSE')
await writeFile(new URL('mermaid.min.js', resources), renderer)
await writeFile(new URL('MERMAID-LICENSE.txt', resources), license)
console.log('Staged Mermaid ' + version + ' and its license for HarmonyOS (' + renderer.length + ' renderer bytes)')
