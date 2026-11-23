#!/usr/bin/env node
/**
 * Automatically distributes an uploaded TestFlight build to External Testing group(s)
 * and submits it for Apple Beta App Review via the App Store Connect REST API v1.
 *
 * Required environment variables:
 *   APPSTORE_API_KEY_ID          - App Store Connect API Key ID
 *   APPSTORE_API_ISSUER_ID       - App Store Connect Issuer ID (UUID)
 *   APPSTORE_API_KEY_P8_PATH     - Path to AuthKey_<KEY_ID>.p8 (or APPSTORE_API_KEY_P8_BASE64)
 *   BUNDLE_ID                    - App bundle identifier (e.g. com.rankchord.nuwa)
 *   APP_VERSION                  - CFBundleShortVersionString / MARKETING_VERSION (e.g. 0.1.35)
 *   BUILD_NUMBER                 - CFBundleVersion / CURRENT_PROJECT_VERSION (e.g. 120)
 *
 * Optional environment variables:
 *   TESTFLIGHT_EXTERNAL_GROUP    - Comma-separated external group names (default: all external groups)
 *   TESTFLIGHT_WHATS_NEW         - "What to Test" notes written to betaBuildLocalizations
 *   TESTFLIGHT_POLL_TIMEOUT_SEC  - Max seconds to wait for Apple build processing (default: 900)
 *   TESTFLIGHT_POLL_INTERVAL_SEC - Polling interval in seconds (default: 20)
 */

import { createPrivateKey, sign } from 'node:crypto'
import { appendFileSync, readFileSync } from 'node:fs'

const API_ORIGIN = 'https://api.appstoreconnect.apple.com'

function requireEnv(name) {
  const value = (process.env[name] ?? '').trim()
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`)
  }
  return value
}

function loadPrivateKeyPem() {
  const path = (process.env.APPSTORE_API_KEY_P8_PATH ?? '').trim()
  if (path) {
    return readFileSync(path, 'utf8')
  }
  const b64 = (process.env.APPSTORE_API_KEY_P8_BASE64 ?? '').trim()
  if (b64) {
    return Buffer.from(b64, 'base64').toString('utf8')
  }
  throw new Error('Set APPSTORE_API_KEY_P8_PATH or APPSTORE_API_KEY_P8_BASE64')
}

function base64Url(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(String(input), 'utf8')
  return buf.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')
}

export function createAscJwt({ keyId, issuerId, privateKeyPem, nowSec = Math.floor(Date.now() / 1000) }) {
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' }
  const payload = {
    iss: issuerId,
    iat: nowSec,
    exp: nowSec + 15 * 60,
    aud: 'appstoreconnect-v1',
  }
  const signingInput = `${base64Url(JSON.stringify(header))}.${base64Url(JSON.stringify(payload))}`
  const key = createPrivateKey(privateKeyPem)
  const signature = sign('sha256', Buffer.from(signingInput, 'utf8'), {
    key,
    dsaEncoding: 'ieee-p1363',
  })
  return `${signingInput}.${base64Url(signature)}`
}

class AscClient {
  constructor({ keyId, issuerId, privateKeyPem }) {
    this.keyId = keyId
    this.issuerId = issuerId
    this.privateKeyPem = privateKeyPem
    this.token = ''
    this.tokenIssuedAt = 0
  }

  getToken() {
    const now = Math.floor(Date.now() / 1000)
    if (!this.token || now - this.tokenIssuedAt >= 10 * 60) {
      this.token = createAscJwt({
        keyId: this.keyId,
        issuerId: this.issuerId,
        privateKeyPem: this.privateKeyPem,
        nowSec: now,
      })
      this.tokenIssuedAt = now
    }
    return this.token
  }

  async request(method, path, body = undefined, { allowStatuses = [] } = {}) {
    const url = path.startsWith('http') ? path : `${API_ORIGIN}${path}`
    const headers = {
      Authorization: `Bearer ${this.getToken()}`,
      Accept: 'application/json',
    }
    let payload
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json'
      payload = JSON.stringify(body)
    }

    const res = await fetch(url, { method, headers, body: payload })
    const raw = await res.text()
    let json = null
    if (raw) {
      try {
        json = JSON.parse(raw)
      } catch {
        json = null
      }
    }

    if (res.ok || allowStatuses.includes(res.status)) {
      return { status: res.status, json, raw }
    }

    const details = Array.isArray(json?.errors)
      ? json.errors.map((e) => `${e.code ?? e.status ?? res.status}: ${e.title ?? ''} ${e.detail ?? ''}`.trim()).join(' | ')
      : raw.slice(0, 500)
    const err = new Error(`App Store Connect API ${method} ${path} failed (HTTP ${res.status}): ${details}`)
    err.status = res.status
    err.errors = json?.errors ?? []
    throw err
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function resolveApp(client, bundleId) {
  const query = new URLSearchParams({
    'filter[bundleId]': bundleId,
    'fields[apps]': 'bundleId,name',
    limit: '5',
  })
  const { json } = await client.request('GET', `/v1/apps?${query.toString()}`)
  const app = (json?.data ?? []).find((item) => item?.attributes?.bundleId === bundleId) ?? json?.data?.[0]
  if (!app?.id) {
    throw new Error(`No App Store Connect app found for bundleId=${bundleId}`)
  }
  return app
}

async function waitForValidBuild(client, { appId, version, buildNumber, timeoutSec, intervalSec }) {
  const deadline = Date.now() + timeoutSec * 1000
  let lastState = ''
  const query = new URLSearchParams({
    'filter[app]': appId,
    'filter[preReleaseVersion.version]': version,
    'filter[version]': buildNumber,
    'fields[builds]': 'version,processingState,usesNonExemptEncryption,expired',
    limit: '5',
  })

  while (true) {
    const { json } = await client.request('GET', `/v1/builds?${query.toString()}`)
    const build = (json?.data ?? []).find((item) => String(item?.attributes?.version ?? '') === String(buildNumber)) ?? json?.data?.[0]
    const state = build?.attributes?.processingState ?? 'NOT_YET_LISTED'
    if (state !== lastState) {
      console.log(`[TestFlight] Build ${version} (${buildNumber}) state: ${state}${build?.id ? ` (id=${build.id})` : ''}`)
      lastState = state
    }

    if (build?.id && state === 'VALID') {
      return build
    }
    if (state === 'INVALID' || state === 'FAILED') {
      throw new Error(`App Store Connect marked build ${version} (${buildNumber}) as ${state}`)
    }
    if (Date.now() >= deadline) {
      throw new Error(`Timed out after ${timeoutSec}s waiting for build ${version} (${buildNumber}) to finish processing (last state: ${state})`)
    }
    await sleep(intervalSec * 1000)
  }
}

async function ensureExportCompliance(client, build) {
  if (build?.attributes?.usesNonExemptEncryption === false) {
    return
  }
  console.log('[TestFlight] Setting usesNonExemptEncryption=false on build...')
  await client.request(
    'PATCH',
    `/v1/builds/${build.id}`,
    {
      data: {
        type: 'builds',
        id: build.id,
        attributes: { usesNonExemptEncryption: false },
      },
    },
    { allowStatuses: [409] }
  )
}

async function updateWhatToTest(client, buildId, whatsNew) {
  const notes = whatsNew.trim().slice(0, 4000)
  if (!notes) return

  const { json } = await client.request('GET', `/v1/builds/${buildId}/betaBuildLocalizations?limit=50`)
  const existing = json?.data ?? []
  if (existing.length > 0) {
    for (const loc of existing) {
      await client.request('PATCH', `/v1/betaBuildLocalizations/${loc.id}`, {
        data: {
          type: 'betaBuildLocalizations',
          id: loc.id,
          attributes: { whatsNew: notes },
        },
      })
      console.log(`[TestFlight] Updated What to Test for locale=${loc.attributes?.locale ?? loc.id}`)
    }
    return
  }

  for (const locale of ['zh-Hans', 'en-US']) {
    const res = await client.request(
      'POST',
      '/v1/betaBuildLocalizations',
      {
        data: {
          type: 'betaBuildLocalizations',
          attributes: { locale, whatsNew: notes },
          relationships: {
            build: { data: { type: 'builds', id: buildId } },
          },
        },
      },
      { allowStatuses: [409] }
    )
    if (res.status >= 200 && res.status < 300) {
      console.log(`[TestFlight] Created What to Test localization (${locale})`)
      return
    }
  }
}

async function resolveExternalGroups(client, appId, requestedFilter) {
  const query = new URLSearchParams({
    'fields[betaGroups]': 'name,isInternalGroup,publicLinkEnabled,publicLink',
    limit: '200',
  })
  const { json } = await client.request('GET', `/v1/apps/${appId}/betaGroups?${query.toString()}`)
  const externalGroups = (json?.data ?? []).filter((group) => group?.attributes?.isInternalGroup === false)

  if (!requestedFilter) {
    return externalGroups
  }
  const wanted = new Set(
    requestedFilter
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean)
  )
  const matched = externalGroups.filter((group) => wanted.has(String(group?.attributes?.name ?? '').trim().toLowerCase()))
  if (matched.length === 0) {
    const available = externalGroups.map((g) => g?.attributes?.name).filter(Boolean).join(', ') || '(none)'
    throw new Error(`Requested external TestFlight group(s) "${requestedFilter}" not found. Available external groups: ${available}`)
  }
  return matched
}

async function attachBuildToGroups(client, buildId, groups) {
  for (const group of groups) {
    const name = group.attributes?.name ?? group.id
    const res = await client.request(
      'POST',
      `/v1/betaGroups/${group.id}/relationships/builds`,
      {
        data: [{ type: 'builds', id: buildId }],
      },
      { allowStatuses: [409] }
    )
    console.log(`[TestFlight] Attached build to external group "${name}" (HTTP ${res.status})`)
  }
}

async function submitBetaAppReview(client, buildId) {
  const existing = await client.request('GET', `/v1/builds/${buildId}/betaAppReviewSubmission`, undefined, {
    allowStatuses: [404],
  })
  const currentState = existing.json?.data?.attributes?.betaReviewState
  if (currentState) {
    console.log(`[TestFlight] Existing betaAppReviewSubmission state: ${currentState}`)
    if (['APPROVED', 'WAITING_FOR_REVIEW', 'IN_REVIEW'].includes(currentState)) {
      return currentState
    }
  }

  const submitted = await client.request(
    'POST',
    '/v1/betaAppReviewSubmissions',
    {
      data: {
        type: 'betaAppReviewSubmissions',
        relationships: {
          build: { data: { type: 'builds', id: buildId } },
        },
      },
    },
    { allowStatuses: [409] }
  )
  if (submitted.status === 409) {
    const detail = submitted.json?.errors?.map((e) => e.detail ?? e.title).filter(Boolean).join('; ') ?? 'already submitted/approved'
    console.log(`[TestFlight] Beta App Review submission returned 409 (${detail})`)
    return `CONFLICT (${detail})`
  }
  const nextState = submitted.json?.data?.attributes?.betaReviewState ?? 'SUBMITTED'
  console.log(`[TestFlight] Submitted for Beta App Review -> state: ${nextState}`)
  return nextState
}

function writeSummary({ appName, version, buildNumber, groups, reviewState }) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY
  if (!summaryPath) return
  const lines = [
    '### TestFlight External Distribution',
    '',
    `- App: **${appName}**`,
    `- Build: \`${version} (${buildNumber})\``,
    `- External Group(s): ${groups.map((g) => `\`${g.attributes?.name ?? g.id}\``).join(', ')}`,
    `- Beta App Review: \`${reviewState}\``,
  ]
  for (const g of groups) {
    if (g.attributes?.publicLinkEnabled && g.attributes?.publicLink) {
      lines.push(`- Public Link (${g.attributes?.name ?? g.id}): ${g.attributes.publicLink}`)
    }
  }
  appendFileSync(summaryPath, `${lines.join('\n')}\n\n`)
}

async function main() {
  const keyId = requireEnv('APPSTORE_API_KEY_ID')
  const issuerId = requireEnv('APPSTORE_API_ISSUER_ID')
  const privateKeyPem = loadPrivateKeyPem()
  const bundleId = requireEnv('BUNDLE_ID')
  const version = requireEnv('APP_VERSION')
  const buildNumber = requireEnv('BUILD_NUMBER')
  const groupFilter = (process.env.TESTFLIGHT_EXTERNAL_GROUP ?? '').trim()
  const whatsNew = (process.env.TESTFLIGHT_WHATS_NEW ?? '').trim() || `Nuwa v${version} (${buildNumber}) 更新与修复`
  const timeoutSec = Math.max(60, Number.parseInt(process.env.TESTFLIGHT_POLL_TIMEOUT_SEC ?? '900', 10) || 900)
  const intervalSec = Math.max(5, Number.parseInt(process.env.TESTFLIGHT_POLL_INTERVAL_SEC ?? '20', 10) || 20)

  const client = new AscClient({ keyId, issuerId, privateKeyPem })

  const app = await resolveApp(client, bundleId)
  const appName = app.attributes?.name ?? bundleId
  console.log(`[TestFlight] Resolved app "${appName}" (id=${app.id}, bundleId=${bundleId})`)

  const groups = await resolveExternalGroups(client, app.id, groupFilter)
  if (groups.length === 0) {
    console.log('::warning::No external TestFlight beta groups found; skipping external distribution.')
    return
  }
  console.log(`[TestFlight] Target external group(s): ${groups.map((g) => g.attributes?.name ?? g.id).join(', ')}`)

  const build = await waitForValidBuild(client, {
    appId: app.id,
    version,
    buildNumber,
    timeoutSec,
    intervalSec,
  })

  await ensureExportCompliance(client, build)
  await updateWhatToTest(client, build.id, whatsNew)
  await attachBuildToGroups(client, build.id, groups)
  const reviewState = await submitBetaAppReview(client, build.id)

  writeSummary({ appName, version, buildNumber, groups, reviewState })
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('distribute-testflight-external.mjs')) {
  main().catch((err) => {
    console.error(`::error::${err instanceof Error ? err.message : String(err)}`)
    process.exit(1)
  })
}
