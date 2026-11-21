import { execFileSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import {
  copyFile, mkdir, mkdtemp, readFile, rename, rm, stat, writeFile,
} from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as zlib from 'node:zlib'

const harmony = fileURLToPath(new URL('../', import.meta.url))
const cache = resolve(process.env.NUWA_OFFLINE_ENGLISH_CACHE || join(harmony, '.cache', 'offline-english'))
const vendor = join(harmony, 'vendor')
const models = join(harmony, 'entry', 'src', 'main', 'resources', 'rawfile', 'en-model')
const version = '2.0.2'
const sherpaCommit = '5d2bd37de78b223a2e8e00e25483d12c5b164299'
const addonCommit = 'c679f6f4c9dc6bf9fc0d99cbe5982bd24a5e2c7b'
const modelCommit = 'd42f2d9f7ca24806fb667456a18a9f1b60f70d16'
const modelSource = 'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/' + modelCommit
const release = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v' + version
const harName = 'sherpa_onnx-' + version + '.har'
const maxTarBytes = 64 * 1024 * 1024

const sherpa = {
  name: 'sherpa-source.tar.gz',
  url: 'https://codeload.github.com/k2-fsa/sherpa-onnx/tar.gz/' + sherpaCommit,
  sha256: '75770c437653fd359e0412a31a43585c4dc12d11c58a9fce44dfa36d1ae21dff',
  size: 12280783,
}
const addon = {
  name: 'napi-source.tar.gz',
  url: 'https://codeload.github.com/nodejs/node-addon-api/tar.gz/' + addonCommit,
  sha256: '5bedae00cf74848e61a308688da0bcebacf2149b9d186ba493ca167571c6db17',
  size: 252741,
}
const nativeSources = [
  {
    abi: 'arm64-v8a',
    machine: 183,
    sha256: '87a5996fd9bf541fa9ba454fdcf12199d0016d0fea817db2be65b1ded22482a2',
    size: 5864110,
    libs: {
      'libonnxruntime.so': 'f9fd9080a10f2b93323d597225fbaa63d06f93b384bdfdd7285db9a9115fcc2b',
      'libsherpa-onnx-c-api.so': '52ec273a3383d8062c381b98d7a26b778903b228ee24aabd3665955b42359e96',
    },
  },
  {
    abi: 'x86_64',
    machine: 62,
    sha256: '3b5bf9c62683be201fa708cef627e892aa3f40b7b4f7f7e0cf2e5e2bd0a0b8a5',
    size: 6609303,
    libs: {
      'libonnxruntime.so': '80abf5a65b6f07977b7d994d79bf5dd380e3db51a947fc571c872c631331c18b',
      'libsherpa-onnx-c-api.so': '8f3354c1855b5d3a284631b9d72f6b1c73bfac778b4f4982ba17146ebaab2bb7',
    },
  },
].map((input) => {
  const prefix = 'sherpa-onnx-v' + version + '-ohos-' + input.abi
  const name = prefix + '.tar.bz2'
  return { ...input, prefix, name, url: release + '/' + name }
})
const modelSources = [
  ['encoder-epoch-99-avg-1.int8.onnx', 42845182, '3810755ce7c3ab26b42a8bcf39d191308fa27fb0f53358823ba46141d03b7eb3'],
  ['decoder-epoch-99-avg-1.onnx', 2092272, '45a7f940ecfb53d89fa270ad11b88b961e53a317203eb24b1c8e95ed208b0f30'],
  ['joiner-epoch-99-avg-1.onnx', 1026462, '343e17dffa4f386ca206e00d3c406908f68f473c3d35968d6c3cddd5b8559a94'],
  ['tokens.txt', 5048, '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb'],
].map(([name, size, sha256]) => ({ name, size, sha256, url: modelSource + '/' + name }))

const sha256 = (data) => createHash('sha256').update(data).digest('hex')

async function hashMatches(path, digest, size) {
  try {
    const info = await stat(path)
    return info.isFile() && (size === undefined || info.size === size) && sha256(await readFile(path)) === digest
  } catch (error) {
    if (error.code === 'ENOENT') return false
    throw error
  }
}

// Publish each verified file with a rename in the destination directory, including on Windows.
async function atomicFile(path, prepare) {
  await mkdir(dirname(path), { recursive: true })
  const temporary = path + '.' + randomUUID() + '.part'
  try {
    await prepare(temporary)
    await rename(temporary, path)
  } finally {
    await rm(temporary, { force: true })
  }
}

async function fetchInput(input) {
  const local = join(cache, 'downloads', input.name)
  if (await hashMatches(local, input.sha256, input.size)) return local
  console.log('Fetching ' + input.name)
  await atomicFile(local, async (tmp) => {
    execFileSync('curl', ['--fail', '--silent', '--show-error', '--location',
      '--proto', '=https', '--proto-redir', '=https', '--retry', '2',
      '--connect-timeout', '15', '--max-time', '180', '--max-filesize', String(input.size),
      '--output', tmp, input.url], { stdio: 'inherit' })
    if (!await hashMatches(tmp, input.sha256, input.size)) {
      throw new Error(input.name + ' does not match its pinned size and SHA-256')
    }
  })
  return local
}

function tarMember(archive, member) {
  return execFileSync('tar', ['-xOf', archive, member], { maxBuffer: maxTarBytes })
}

async function findCli() {
  const candidates = [
    process.env.NUWA_HARMONY_CLI,
    process.env.DEVECO_SDK_HOME,
    process.env.HOS_SDK_HOME,
    process.env.OHPM_HOME,
  ].filter(Boolean)
  for (const path of candidates) {
    for (const root of [resolve(path), dirname(resolve(path))]) {
      try {
        const sdk = join(root, 'sdk')
        const identity = await readFile(join(sdk, 'default', 'sdk-pkg.json'))
        const ohpm = join(root, 'ohpm', 'bin', 'pm-cli.js')
        const hvigor = join(root, 'hvigor', 'bin', 'hvigorw.js')
        await Promise.all([stat(ohpm), stat(hvigor)])
        return { root, sdk, identity, ohpm, hvigor }
      } catch (error) {
        if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error
      }
    }
  }
  throw new Error('Set NUWA_HARMONY_CLI to the HarmonyOS command-line-tools directory, or initialize its SDK environment')
}

// The official N-API patch gives HarmonyOS the byte-length output pointer it requires.
// The source archive is outside Git, so apply the exact hunk even inside a Nuwa worktree.
async function patchAddon(project, addonDir) {
  const patch = await readFile(join(project, 'sherpa_onnx', 'src', 'main', 'cpp', 'my-patch.diff'), 'utf8')
  const oldLine = '  napi_status status = napi_get_arraybuffer_info(_env, _value, &data, nullptr);'
  const newLines = [
    '  size_t byte_length;',
    '  napi_status status = napi_get_arraybuffer_info(_env, _value, &data, &byte_length);',
  ]
  if (!patch.includes('-' + oldLine + '\n+' + newLines.join('\n+'))) {
    throw new Error('The upstream HarmonyOS N-API patch changed')
  }
  const header = join(addonDir, 'napi-inl.h')
  const source = await readFile(header, 'utf8')
  if (source.split(oldLine).length !== 2) throw new Error('Could not apply the HarmonyOS N-API patch exactly once')
  await writeFile(header, source.replace(oldLine, newLines.join('\n')))
}

function normalizeHar(gzip) {
  let tar
  try {
    tar = zlib.gunzipSync(gzip, { maxOutputLength: maxTarBytes })
  } catch (error) {
    // Hvigor can produce a gzip that Node's header reader rejects. Verify its single
    // member, including the original CRC and uncompressed size, before recompressing.
    if (gzip.length < 18 || !gzip.subarray(0, 4).equals(Buffer.from([31, 139, 8, 0]))) throw error
    const payload = gzip.subarray(10, -8)
    const inflated = zlib.inflateRawSync(payload, { info: true, maxOutputLength: maxTarBytes })
    tar = inflated.buffer
    if (inflated.engine.bytesWritten !== payload.length || zlib.crc32(tar) !== gzip.readUInt32LE(gzip.length - 8)
        || tar.length !== gzip.readUInt32LE(gzip.length - 4)) throw error
  }
  // Stored deflate blocks also work with OHPM's streaming extractor.
  const normalized = zlib.gzipSync(tar, { level: 0 })
  if (!zlib.gunzipSync(normalized, { maxOutputLength: maxTarBytes }).equals(tar)) {
    throw new Error('HAR gzip normalization failed')
  }
  return normalized
}

function verifyBridge(elf, { abi, machine, libs }) {
  const invalid = (reason) => new Error('Invalid native bridge for ' + abi + ': ' + reason)
  if (elf.length < 64 || !elf.subarray(0, 7).equals(Buffer.from([127, 69, 76, 70, 2, 1, 1])) ||
      elf.readUInt16LE(18) !== machine) {
    throw invalid('wrong ELF architecture')
  }
  const word = (offset) => {
    const value = Number(elf.readBigUInt64LE(offset))
    if (!Number.isSafeInteger(value)) throw invalid('ELF offset exceeds the safe integer range')
    return value
  }
  const programOffset = word(32)
  const programEntrySize = elf.readUInt16LE(54)
  const programCount = elf.readUInt16LE(56)
  if (programEntrySize < 56 || programCount === 0 || programOffset > elf.length - programEntrySize * programCount) {
    throw invalid('invalid ELF program header table')
  }

  // Locate PT_LOAD and PT_DYNAMIC even when the section headers have been stripped.
  const segments = []
  for (let index = 0; index < programCount; index++) {
    const entry = programOffset + index * programEntrySize
    const type = elf.readUInt32LE(entry)
    if (type !== 1 && type !== 2) continue
    const offset = word(entry + 8)
    const address = word(entry + 16)
    const size = word(entry + 32)
    if (offset > elf.length - size) throw invalid('ELF segment is outside the file')
    segments.push({ type, offset, address, size })
  }
  const dynamic = segments.find(({ type }) => type === 2)
  if (!dynamic) throw invalid('missing ELF dynamic segment')
  let stringAddress
  let stringSize
  let terminated = false
  const paths = []
  const needed = []
  for (let entry = dynamic.offset; entry <= dynamic.offset + dynamic.size - 16; entry += 16) {
    const tag = elf.readBigInt64LE(entry)
    if (tag === 0n) {
      terminated = true
      break
    }
    if (tag === 1n) needed.push(word(entry + 8)) // DT_NEEDED
    if (tag === 5n) stringAddress = word(entry + 8) // DT_STRTAB
    if (tag === 10n) stringSize = word(entry + 8) // DT_STRSZ
    if (tag === 15n || tag === 29n) paths.push(word(entry + 8)) // DT_RPATH or DT_RUNPATH
  }
  if (!terminated || stringAddress === undefined || !stringSize) {
    throw invalid('incomplete ELF dynamic table')
  }

  const strings = segments.find(({ type, address, size }) =>
    type === 1 && stringAddress >= address && stringAddress - address <= size - stringSize)
  if (!strings) throw invalid('ELF dynamic strings are outside the file')
  const stringOffset = strings.offset + (stringAddress - strings.address)
  const readString = (offset) => {
    if (offset >= stringSize) throw invalid('invalid ELF dynamic string offset')
    const start = stringOffset + offset
    const end = elf.indexOf(0, start)
    if (end < 0 || end >= stringOffset + stringSize) throw invalid('unterminated ELF dynamic string')
    return elf.toString('utf8', start, end)
  }
  for (const offset of paths) {
    if (readString(offset).split(':').some((path) => path !== '$ORIGIN' && path !== '${ORIGIN}')) {
      throw invalid('ELF runtime search path is not relative to the shared library')
    }
  }
  const dependencies = new Set(needed.map(readString))
  for (const name of Object.keys(libs)) {
    if (!dependencies.has(name)) throw invalid('missing ELF dependency ' + name)
  }
}

function verifyHar(archive) {
  const manifest = JSON.parse(tarMember(archive, 'package/oh-package.json5'))
  if (manifest.name !== 'sherpa_onnx' || manifest.version !== version) {
    throw new Error('Unexpected HAR package name or version')
  }
  for (const input of nativeSources) {
    const directory = 'package/libs/' + input.abi + '/'
    // Hvigor strips the bridge, but the upstream core binaries already come stripped.
    for (const [name, sha] of Object.entries(input.libs)) {
      if (sha256(tarMember(archive, directory + name)) !== sha) throw new Error('Unexpected packaged ' + input.abi + '/' + name)
    }
    verifyBridge(tarMember(archive, directory + 'libsherpa_onnx.so'), input)
  }
}

async function buildHar(cli, archiveOutput, inputs) {
  // The Windows SDK's CMake TryCompile nests object directories deeply.
  const buildRoot = resolve(tmpdir())
  const workspace = await mkdtemp(join(buildRoot, 'nuwa-en-'))
  const project = join(workspace, 'har')
  const addonDir = join(workspace, 'napi')
  await Promise.all([mkdir(project), mkdir(addonDir)])
  const sherpaPrefix = 'sherpa-onnx-' + sherpaCommit
  const projectPrefix = sherpaPrefix + '/harmony-os/SherpaOnnxHar'
  const headerMember = 'sherpa_onnx/src/main/cpp/include/sherpa-onnx/c-api/c-api.h'
  const header = tarMember(inputs.get(sherpa.name), sherpaPrefix + '/sherpa-onnx/c-api/c-api.h')
  try {
    execFileSync('tar', ['-xf', inputs.get(sherpa.name), '-C', project, '--strip-components=3',
      '--exclude=' + projectPrefix + '/' + headerMember, projectPrefix])
    execFileSync('tar', ['-xf', inputs.get(addon.name), '-C', addonDir, '--strip-components=1'])
    await writeFile(join(project, headerMember), header)
    for (const input of nativeSources) {
      const archive = inputs.get(input.name)
      if (!tarMember(archive, input.prefix + '/include/sherpa-onnx/c-api/c-api.h').equals(header)) {
        throw new Error('Upstream ' + input.abi + ' C API header does not match the pinned source')
      }
      const native = join(project, 'sherpa_onnx', 'src', 'main', 'cpp', 'libs', input.abi)
      await mkdir(native, { recursive: true })
      for (const [name, sha] of Object.entries(input.libs)) {
        const library = tarMember(archive, input.prefix + '/lib/' + name)
        if (sha256(library) !== sha) throw new Error('Upstream native library digest changed for ' + name)
        await writeFile(join(native, name), library)
      }
    }
    await patchAddon(project, addonDir)
    const cmakeFile = join(project, 'sherpa_onnx', 'src', 'main', 'cpp', 'CMakeLists.txt')
    const cmake = await readFile(cmakeFile, 'utf8')
    const dependency = 'FetchContent_Declare(node_addon_api'
    if (!cmake.includes(dependency)) throw new Error('Unexpected Sherpa HAR CMake source')
    const pinnedCmake = cmake.replace(dependency, [
      'set(FETCHCONTENT_FULLY_DISCONNECTED ON)',
      'set(FETCHCONTENT_SOURCE_DIR_NODE_ADDON_API "${CMAKE_CURRENT_LIST_DIR}/../../../../../napi")',
      dependency,
    ].join('\n'))
    await writeFile(cmakeFile, pinnedCmake + [
      '',
      'set_target_properties(sherpa_onnx PROPERTIES',
      '  BUILD_WITH_INSTALL_RPATH TRUE',
      '  INSTALL_RPATH "$ORIGIN"',
      ')',
      '',
    ].join('\n'))
    const rootPackage = join(project, 'oh-package.json5')
    const manifest = JSON.parse(await readFile(rootPackage, 'utf8'))
    delete manifest.devDependencies
    await writeFile(rootPackage, JSON.stringify(manifest, null, 2) + '\n')

    const env = {
      ...process.env,
      DEVECO_SDK_HOME: cli.sdk,
      HOS_SDK_HOME: cli.sdk,
      OHPM_HOME: join(cli.root, 'ohpm'),
      HVIGOR_USER_HOME: process.env.HVIGOR_USER_HOME || join(cache, 'hvigor'),
    }
    const jdk = join(dirname(cli.root), 'jdk-17')
    if (!env.JAVA_HOME && await stat(jdk).then((info) => info.isDirectory(), () => false)) env.JAVA_HOME = jdk
    execFileSync(process.execPath, [cli.ohpm, 'install', '--all', '--cache', join(workspace, 'ohpm-cache')], {
      cwd: project, env, stdio: 'inherit',
    })
    console.log('Assembling Sherpa-ONNX v' + version + ' HarmonyOS HAR for arm64-v8a and x86_64')
    execFileSync(process.execPath, [cli.hvigor, '--mode', 'module',
      '-p', 'product=default', '-p', 'module=sherpa_onnx@default', '-p', 'buildMode=release',
      'assembleHar', '--no-daemon'], { cwd: project, env, stdio: 'inherit' })
    const rawHar = join(project, 'sherpa_onnx', 'build', 'default', 'outputs', 'default', 'sherpa_onnx.har')
    const normalized = normalizeHar(await readFile(rawHar))
    await atomicFile(archiveOutput, async (path) => {
      await writeFile(path, normalized)
      verifyHar(path)
    })
    const workRelative = relative(buildRoot, workspace)
    if (workRelative === basename(workspace) && workRelative.startsWith('nuwa-en-')) await rm(workspace, { recursive: true })
  } catch (error) {
    throw new Error('Sherpa HAR preparation failed. Build files kept in ' + workspace, { cause: error })
  }
}

async function main() {
  if (typeof zlib.crc32 !== 'function') throw new Error('Node.js 22.2 or later is required')
  const cli = await findCli()
  const key = sha256(Buffer.concat([cli.identity, Buffer.from(process.platform), await readFile(fileURLToPath(import.meta.url))]))
  const archive = join(cache, 'har', key, harName)
  const checksumPath = archive + '.sha256'
  const recorded = await readFile(checksumPath, 'utf8').then((value) => value.trim(), (error) => {
    if (error.code === 'ENOENT') return ''
    throw error
  })
  const localModels = await Promise.all(modelSources.map(async (input) => {
    const target = join(models, input.name)
    return [target, await hashMatches(target, input.sha256, input.size) ? target : await fetchInput(input)]
  }))
  if (!/^[a-f0-9]{64}$/.test(recorded) || !await hashMatches(archive, recorded)) {
    const packageInputs = [sherpa, addon, ...nativeSources]
    const inputs = new Map(await Promise.all(packageInputs.map(async (input) => [input.name, await fetchInput(input)])))
    await buildHar(cli, archive, inputs)
    const digest = sha256(await readFile(archive))
    await atomicFile(checksumPath, (path) => writeFile(path, digest + '\n'))
  } else {
    verifyHar(archive)
  }
  const targetHar = join(vendor, harName)
  const digest = sha256(await readFile(archive))
  for (const [target, input] of localModels) {
    if (target !== input) await atomicFile(target, (temporary) => copyFile(input, temporary))
  }
  if (!await hashMatches(targetHar, digest)) {
    await atomicFile(targetHar, (temporary) => copyFile(archive, temporary))
  }
  console.log('Prepared ' + harName + ' and ' + localModels.length + ' offline English model files')
  console.log('HAR SHA-256 ' + digest)
}

await main()
