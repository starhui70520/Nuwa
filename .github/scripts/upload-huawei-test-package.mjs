import { constants, createHash, createPrivateKey, sign } from 'node:crypto'
import { openAsBlob } from 'node:fs'
import { request as httpsRequest } from 'node:https'
import { basename } from 'node:path'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { setTimeout as delay } from 'node:timers/promises'
import { pathToFileURL } from 'node:url'

const API_ORIGIN = 'https://connect-api.cloud.huawei.com'
const TOKEN_AUDIENCE = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token'
const MAX_PACKAGE_BYTES = 4 * 1024 ** 3
const API_TIMEOUT_MS = 20_000
const UPLOAD_TIMEOUT_MS = 240_000
const POLL_INTERVAL_MS = 10_000
const MAX_POLLS = 60

class UploadError extends Error {
  constructor(message, retryable = false) {
    super(message)
    this.retryable = retryable
  }
}

const encodeJson = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')

function createServiceToken(secretJson) {
  if (!secretJson) {
    throw new UploadError('Set the HUAWEI_SERVICE_ACCOUNT_JSON secret to the downloaded service account JSON.')
  }
  let credentials
  try {
    credentials = JSON.parse(secretJson.replace(/^\uFEFF/, ''))
  } catch {
    throw new UploadError('HUAWEI_SERVICE_ACCOUNT_JSON is not valid JSON.')
  }
  const { key_id: keyId, private_key: privateKey, sub_account: account } = credentials ?? {}
  if ([keyId, privateKey, account].some((value) => typeof value !== 'string' || !value.trim())) {
    throw new UploadError('The service account JSON must contain key_id, private_key and sub_account.')
  }

  const issuedAt = Math.floor(Date.now() / 1000)
  const header = encodeJson({ kid: keyId, typ: 'JWT', alg: 'PS256' })
  const claims = encodeJson({ aud: TOKEN_AUDIENCE, iss: account, exp: issuedAt + 3600, iat: issuedAt })
  const message = `${header}.${claims}`
  try {
    const signature = sign('sha256', Buffer.from(message), {
      key: createPrivateKey(privateKey),
      padding: constants.RSA_PKCS1_PSS_PADDING,
      saltLength: constants.RSA_PSS_SALTLEN_DIGEST,
    })
    return `${message}.${signature.toString('base64url')}`
  } catch {
    throw new UploadError('The service account private_key could not sign a PS256 token.')
  }
}

function safeCode(value) {
  return /^[A-Za-z0-9_-]{1,64}$/.test(String(value ?? '')) ? String(value) : 'unknown'
}

function httpError(label, status) {
  const retryable = status === 408 || status === 429 || status >= 500
  return new UploadError(`${label} failed with HTTP ${status}.`, retryable)
}

async function requestApi(fetchImpl, token, label, path, query, body) {
  const target = new URL(path, API_ORIGIN)
  target.search = new URLSearchParams(query)
  let response
  try {
    response = await fetchImpl(target, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: 'error',
      signal: AbortSignal.timeout(API_TIMEOUT_MS),
    })
  } catch {
    throw new UploadError(`${label} could not connect or timed out.`, true)
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {})
    throw httpError(label, response.status)
  }
  let result
  try {
    result = await response.json()
  } catch {
    throw new UploadError(`${label} did not return a valid JSON response.`)
  }
  const code = result?.ret?.code
  if (code !== 0 && code !== '0') {
    throw new UploadError(`${label} failed with Huawei response code ${safeCode(code)}.`)
  }
  return result
}

async function retryTemporary(operation, pause) {
  for (const wait of [1000, 3000]) {
    try {
      return await operation()
    } catch (error) {
      if (!(error instanceof UploadError) || !error.retryable) {
        throw error
      }
      await pause(wait)
    }
  }
  return operation()
}

async function readPackage(appPath) {
  const fileName = basename(appPath)
  if (!/\.app$/i.test(fileName) || fileName.length > 255) {
    throw new UploadError('Pass a signed HarmonyOS .app file with a filename of at most 255 characters.')
  }
  try {
    // openAsBlob streams the file without keeping the package in memory and detects file changes.
    const blob = await openAsBlob(appPath, { type: 'application/octet-stream' })
    if (blob.size < 1 || blob.size > MAX_PACKAGE_BYTES) {
      throw new UploadError('The .app file must be nonempty and at most 4 GiB.')
    }
    const hash = createHash('sha256')
    for await (const chunk of blob.stream()) {
      hash.update(chunk)
    }
    return { blob, fileName, sha256: hash.digest('hex') }
  } catch (error) {
    if (error instanceof UploadError) {
      throw error
    }
    throw new UploadError('The .app file could not be read or changed while calculating its checksum.')
  }
}

function storageRequest(urlInfo, blob) {
  if (urlInfo?.method !== 'PUT' || typeof urlInfo.objectId !== 'string' || !urlInfo.objectId) {
    throw new UploadError('Huawei did not return a valid storage PUT method and object ID.')
  }
  let target
  let headers
  try {
    target = new URL(urlInfo.url)
    headers = new Headers(urlInfo.headers)
  } catch {
    throw new UploadError('Huawei returned an invalid storage URL or signed headers.')
  }
  if (target.protocol !== 'https:' || target.username || target.password || target.hash) {
    throw new UploadError('Huawei returned an unexpected storage URL.')
  }
  const requiredHeaders = ['authorization', 'x-amz-content-sha256', 'x-amz-date', 'host', 'user-agent', 'content-type']
  if (requiredHeaders.some((name) => !headers.get(name)) || headers.get('content-type') !== blob.type) {
    throw new UploadError('Huawei did not return the expected signed headers for a binary upload.')
  }
  const contentLength = String(blob.size)
  if (headers.has('content-length') && headers.get('content-length') !== contentLength) {
    throw new UploadError('Huawei returned a storage content length that differs from the package size.')
  }
  headers.set('content-length', contentLength)
  return { target, options: { method: 'PUT', headers, body: blob } }
}

async function transferStorageFile(target, { method, headers, body }) {
  // Fetch replaces the Host header. The HTTPS client preserves Huawei's signed headers.
  const request = httpsRequest(target, {
    method,
    headers: Object.fromEntries(headers),
    signal: AbortSignal.timeout(UPLOAD_TIMEOUT_MS),
  })
  const receivedStatus = new Promise((resolve, reject) => {
    request.once('error', reject)
    request.once('response', (response) => {
      response.once('error', reject)
      response.once('end', () => resolve(response.statusCode))
      response.resume()
    })
  })
  const [status] = await Promise.all([receivedStatus, pipeline(Readable.fromWeb(body.stream()), request)])
  return status
}

export async function uploadTestPackage(appPath, {
  env = process.env,
  fetchImpl = fetch,
  storageUpload = transferStorageFile,
  pause = delay,
  progress = console.log,
} = {}) {
  const appId = env.HUAWEI_APP_ID?.trim()
  if (!/^\d{1,32}$/.test(appId ?? '')) {
    throw new UploadError('Set HUAWEI_APP_ID to the numeric App ID from HarmonyOS Developer Center.')
  }
  const chineseMainlandFlag = env.HUAWEI_CHINESE_MAINLAND_FLAG?.trim() || '1'
  if (chineseMainlandFlag !== '0' && chineseMainlandFlag !== '1') {
    throw new UploadError('HUAWEI_CHINESE_MAINLAND_FLAG must be 0 or 1.')
  }
  const token = createServiceToken(env.HUAWEI_SERVICE_ACCOUNT_JSON)
  const { blob, fileName, sha256 } = await readPackage(appPath)

  const objectId = await retryTemporary(async () => {
    // Get a fresh signature on each attempt, since the upload URL only lasts about five minutes.
    const { urlInfo } = await requestApi(
      fetchImpl, token, 'Getting a storage URL', '/api/publish/v2/upload-url/for-obs',
      { appId, fileName, sha256, contentLength: String(blob.size), chineseMainlandFlag },
    )
    const { target, options } = storageRequest(urlInfo, blob)
    let status
    try {
      status = await storageUpload(target, options)
    } catch {
      throw new UploadError('Uploading the .app file could not connect or timed out.', true)
    }
    if (status !== 200) {
      throw httpError('Uploading the .app file', status)
    }
    return urlInfo.objectId
  }, pause)

  let registration
  try {
    // Mode 1 is the testing area. Registration is kept separate from submitting a test or release.
    // This POST is not retried because a timeout may occur after Huawei has registered the package.
    registration = await requestApi(
      fetchImpl, token, 'Registering the test package', '/api/publish/v2/test/version/pkg', { appId },
      { distributeMode: 1, file: { fileName, objectId } },
    )
  } catch (error) {
    if (error instanceof UploadError) {
      throw new UploadError(`${error.message} Check Huawei's testing package inventory before retrying.`)
    }
    throw error
  }
  const packageId = registration.pkgVersion?.[0]
  if (!Array.isArray(registration.pkgVersion) || typeof packageId !== 'string' || safeCode(packageId) !== packageId) {
    throw new UploadError('Huawei did not return a test package ID. Check the testing package inventory before retrying.')
  }
  progress(`Huawei test package ${packageId} is registered. Waiting for package analysis.`)

  for (let attempt = 0; attempt < MAX_POLLS; attempt++) {
    const { pkgStateList } = await retryTemporary(() => requestApi(
      fetchImpl, token, 'Checking test package analysis', '/api/publish/v3/package/compile/status',
      { appId, pkgIds: packageId },
    ), pause)
    if (!Array.isArray(pkgStateList)) {
      throw new UploadError(`Huawei did not return analysis status for test package ${packageId}.`)
    }
    const state = pkgStateList.find((entry) => entry?.pkgId === packageId)
    if (state?.successStatus === 0) {
      return packageId
    }
    if (state?.successStatus === 2) {
      const detail = state.errorCode ? ` (code ${safeCode(state.errorCode)})` : ''
      throw new UploadError(`Huawei could not analyze test package ${packageId}${detail}.`)
    }
    if (state && state.successStatus !== 1) {
      throw new UploadError(`Huawei returned an unknown analysis status for test package ${packageId}.`)
    }
    await pause(POLL_INTERVAL_MS)
  }
  throw new UploadError(`Test package ${packageId} is registered, but analysis is still pending. Check Huawei before rerunning.`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length !== 3) {
      throw new UploadError('Usage: node .github/scripts/upload-huawei-test-package.mjs <signed.app>')
    }
    const packageId = await uploadTestPackage(process.argv[2])
    console.log(`Huawei test package ${packageId} passed analysis and is ready in the testing package inventory.`)
  } catch (error) {
    // Only print messages built locally from known fields.
    console.error(error instanceof UploadError ? error.message : 'Huawei test package upload failed.')
    process.exitCode = 1
  }
}
