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

function yamlTitleScript(mermaidLicense) {
  // The pinned Mermaid tarball ships js-yaml and its only import, the shared esbuild name helper.
  const chunks = 'dist/chunks/mermaid.core/'
  const runtime = readMember(chunks + 'chunk-Y2CYZVJY.mjs').toString('utf8')
  const parser = readMember(chunks + 'chunk-LNGE3PJU.mjs').toString('utf8')
  const runtimeBody = /^([\s\S]+)\nexport \{\s*__name,\s*__export\s*\};\s*$/.exec(runtime)?.[1]
  const parserBody = /^import \{\s*__name\s*\} from "\.\/chunk-Y2CYZVJY\.mjs";\s*([\s\S]+)\nexport \{\s*JSON_SCHEMA,\s*load\s*\};\s*$/.exec(parser)?.[1]
  if (!runtimeBody || !parserBody) {
    throw new Error('The pinned Mermaid YAML parser bundle has changed')
  }
  const license = mermaidLicense.toString('utf8').replace(/^Copyright.*$/m,
    'Copyright (C) 2011-2015 by Vitaly Puzrin')
  return '/* js-yaml 4.3.0\n' + license + '\n*/\n' +
    '(() => {\n"use strict";\n' + runtimeBody + '\n' + parserBody + '\n' +
    'window.NuwaMermaidYamlTitle = (fields) => {\n' +
    '  const data = load(fields, { schema: JSON_SCHEMA });\n' +
    '  if (!data || typeof data !== "object" || Array.isArray(data) || !Object.hasOwn(data, "title")) return "";\n' +
    '  const title = data.title;\n' +
    '  return title && ["string", "number", "boolean"].includes(typeof title) ? String(title) : "";\n' +
    '};\n})();\n'
}

await prepareArchive()
const renderer = readMember('dist/mermaid.min.js')
const license = readMember('LICENSE')
const yamlTitle = yamlTitleScript(license)
await writeFile(new URL('mermaid.min.js', resources), renderer)
await writeFile(new URL('MERMAID-LICENSE.txt', resources), license)
await writeFile(new URL('yaml-title.js', resources), yamlTitle)
console.log('Staged Mermaid ' + version + ' and its license for HarmonyOS (' + renderer.length + ' renderer bytes)')
