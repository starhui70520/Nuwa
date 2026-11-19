import { useEffect, useState } from 'react'
import {
  collectDeviceInfo,
  getAppLogs,
  ISSUE_TYPE_OPTIONS,
  submitIssueReport,
  type AppDeviceInfo,
  type AppLogEntry,
} from '../../services/errorLog.js'
import { Button } from '../base/Button.js'

export const FeedbackReportPage = () => {
  const [issueType, setIssueType] = useState<string>(ISSUE_TYPE_OPTIONS[0])
  const [description, setDescription] = useState('')
  const [contact, setContact] = useState('')
  const [includeLogs, setIncludeLogs] = useState(true)
  const [showPreview, setShowPreview] = useState(false)
  const [logs, setLogs] = useState<AppLogEntry[]>(() => getAppLogs())
  const [deviceInfo, setDeviceInfo] = useState<AppDeviceInfo | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [reportCode, setReportCode] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    setLogs(getAppLogs())
    void collectDeviceInfo().then(setDeviceInfo)
  }, [])

  const handleSubmit = async () => {
    if (!description.trim()) {
      setSubmitError('请简要描述您遇到的问题')
      return
    }
    setSubmitting(true)
    setSubmitError(null)
    try {
      const result = await submitIssueReport({
        issueType,
        description,
        contact,
        includeLogs,
      })
      setReportCode(result.code)
      setCopied(false)
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : String(err))
    } finally {
      setSubmitting(false)
    }
  }

  const handleCopyCode = async () => {
    if (!reportCode) {
      return
    }
    try {
      await navigator.clipboard.writeText(reportCode)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    } catch {
      setCopied(false)
    }
  }

  if (reportCode) {
    return (
      <div
        style={{
          padding: '20px',
          borderRadius: '16px',
          backgroundColor: 'var(--dsw-alias-bg-layer-2, rgba(128,128,128,0.08))',
          textAlign: 'center',
        }}
      >
        <div style={{ fontSize: '16px', fontWeight: 600, marginBottom: '8px' }}>
          日志上报成功
        </div>
        <div
          style={{
            fontSize: '13px',
            color: 'var(--dsw-alias-label-secondary, #666)',
            marginBottom: '16px',
            lineHeight: '20px',
          }}
        >
          请将下方记录码发给开发者，我们会根据记录码快速定位并修复您遇到的问题。
        </div>
        <div
          style={{
            padding: '14px 16px',
            borderRadius: '12px',
            backgroundColor: 'var(--dsw-alias-bg-base, #fff)',
            border: '1px solid var(--dsw-alias-border-l1, rgba(128,128,128,0.2))',
            fontFamily: 'monospace',
            fontSize: '22px',
            fontWeight: 700,
            letterSpacing: '1.5px',
            marginBottom: '16px',
            userSelect: 'all',
          }}
        >
          {reportCode}
        </div>
        <div style={{ display: 'flex', gap: '10px', justifyContent: 'center', flexWrap: 'wrap' }}>
          <Button variant="primary" size="m" onClick={() => void handleCopyCode()}>
            {copied ? '已复制记录码' : '复制记录码'}
          </Button>
          <Button
            variant="outlined"
            size="m"
            onClick={() => {
              setReportCode(null)
              setDescription('')
              setSubmitError(null)
              setLogs(getAppLogs())
            }}
          >
            继续提交新反馈
          </Button>
        </div>
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '14px' }}>
      <div
        style={{
          padding: '16px',
          borderRadius: '16px',
          backgroundColor: 'var(--dsw-alias-bg-layer-2, rgba(128,128,128,0.08))',
          display: 'flex',
          flexDirection: 'column',
          gap: '14px',
        }}
      >
        <div>
          <label
            style={{
              display: 'block',
              fontSize: '13px',
              fontWeight: 500,
              marginBottom: '8px',
            }}
          >
            遇到的问题
          </label>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px' }}>
            {ISSUE_TYPE_OPTIONS.map((opt) => {
              const active = issueType === opt
              return (
                <button
                  key={opt}
                  type="button"
                  onClick={() => setIssueType(opt)}
                  style={{
                    padding: '6px 12px',
                    borderRadius: '999px',
                    fontSize: '12px',
                    cursor: 'pointer',
                    border: active
                      ? '1px solid #4d6bfe'
                      : '1px solid var(--dsw-alias-border-l1, rgba(128,128,128,0.25))',
                    backgroundColor: active
                      ? 'rgba(77, 107, 254, 0.14)'
                      : 'var(--dsw-alias-bg-base, transparent)',
                    color: active ? '#4d6bfe' : 'inherit',
                    fontWeight: active ? 600 : 400,
                  }}
                >
                  {opt}
                </button>
              )
            })}
          </div>
        </div>

        <div>
          <label
            htmlFor="nuwa-feedback-desc"
            style={{
              display: 'block',
              fontSize: '13px',
              fontWeight: 500,
              marginBottom: '6px',
            }}
          >
            问题描述 *
          </label>
          <textarea
            id="nuwa-feedback-desc"
            rows={4}
            value={description}
            onChange={(e) => {
              setDescription(e.target.value)
              if (submitError) {
                setSubmitError(null)
              }
            }}
            placeholder="请描述遇到的问题、出现前进行了什么操作，方便我们复现与定位…"
            style={{
              width: '100%',
              boxSizing: 'border-box',
              padding: '10px 12px',
              borderRadius: '12px',
              border: '1px solid var(--dsw-alias-border-l1, rgba(128,128,128,0.25))',
              backgroundColor: 'var(--dsw-alias-bg-base, #ffffff)',
              color: 'inherit',
              fontSize: '13px',
              lineHeight: '20px',
              resize: 'vertical',
              outline: 'none',
            }}
          />
        </div>

        <div>
          <label
            htmlFor="nuwa-feedback-contact"
            style={{
              display: 'block',
              fontSize: '13px',
              fontWeight: 500,
              marginBottom: '6px',
            }}
          >
            联系方式（选填）
          </label>
          <input
            id="nuwa-feedback-contact"
            type="text"
            value={contact}
            onChange={(e) => setContact(e.target.value)}
            placeholder="微信号 / 邮箱，方便修复后通知您"
            style={{
              width: '100%',
              boxSizing: 'border-box',
              height: '38px',
              padding: '0 12px',
              borderRadius: '10px',
              border: '1px solid var(--dsw-alias-border-l1, rgba(128,128,128,0.25))',
              backgroundColor: 'var(--dsw-alias-bg-base, #ffffff)',
              color: 'inherit',
              fontSize: '13px',
              outline: 'none',
            }}
          />
        </div>

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: '8px',
            flexWrap: 'wrap',
            fontSize: '12px',
            color: 'var(--dsw-alias-label-secondary, #666)',
          }}
        >
          <label style={{ display: 'inline-flex', alignItems: 'center', gap: '6px', cursor: 'pointer' }}>
            <input
              type="checkbox"
              checked={includeLogs}
              onChange={(e) => setIncludeLogs(e.target.checked)}
            />
            <span>附带设备信息与最近 {logs.length} 条脱敏错误日志（不含 API Key）</span>
          </label>
          <button
            type="button"
            onClick={() => setShowPreview((v) => !v)}
            style={{
              border: 'none',
              background: 'none',
              color: '#4d6bfe',
              fontSize: '12px',
              cursor: 'pointer',
              padding: 0,
            }}
          >
            {showPreview ? '收起预览' : '预览附带信息'}
          </button>
        </div>

        {showPreview ? (
          <pre
            style={{
              margin: 0,
              padding: '10px 12px',
              borderRadius: '10px',
              backgroundColor: 'var(--dsw-alias-bg-base, rgba(0,0,0,0.04))',
              border: '1px solid var(--dsw-alias-border-l1, rgba(128,128,128,0.2))',
              fontSize: '11px',
              lineHeight: '16px',
              maxHeight: '160px',
              overflow: 'auto',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-all',
            }}
          >
            {JSON.stringify(
              {
                deviceInfo,
                recentLogs: logs.slice(-8),
              },
              null,
              2
            )}
          </pre>
        ) : null}

        {submitError ? (
          <div style={{ fontSize: '12px', color: '#e5484d' }}>{submitError}</div>
        ) : null}

        <Button
          variant="primary"
          size="m"
          disabled={submitting}
          onClick={() => void handleSubmit()}
        >
          {submitting ? '正在提交…' : '提交日志上报'}
        </Button>
      </div>
    </div>
  )
}
