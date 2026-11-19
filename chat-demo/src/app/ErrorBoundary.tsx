import { Component, type ErrorInfo, type ReactNode } from 'react'
import { recordAppLog, submitIssueReport } from '../services/errorLog.js'

type ErrorBoundaryProps = {
  children: ReactNode
}

type ErrorBoundaryState = {
  error: Error | null
  showReportForm: boolean
  description: string
  submitting: boolean
  reportCode: string | null
  reportError: string | null
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  override state: ErrorBoundaryState = {
    error: null,
    showReportForm: false,
    description: '',
    submitting: false,
    reportCode: null,
    reportError: null,
  }

  static getDerivedStateFromError(error: Error): Partial<ErrorBoundaryState> {
    return { error }
  }

  override componentDidCatch(error: Error, info: ErrorInfo): void {
    const detail = [error.stack, info.componentStack].filter(Boolean).join('\n')
    recordAppLog('error', 'ErrorBoundary', error.message || 'React render error', detail)
  }

  private handleSubmitReport = async () => {
    const { error, description } = this.state
    this.setState({ submitting: true, reportError: null })
    try {
      const result = await submitIssueReport({
        issueType: '页面白屏或闪退',
        description:
          description.trim() || `页面渲染异常：${error?.message || 'Unknown error'}`,
        includeLogs: true,
      })
      this.setState({ submitting: false, reportCode: result.code })
    } catch (err) {
      this.setState({
        submitting: false,
        reportError: err instanceof Error ? err.message : String(err),
      })
    }
  }

  override render(): ReactNode {
    if (!this.state.error) {
      return this.props.children
    }

    const { error, showReportForm, description, submitting, reportCode, reportError } = this.state
    const message = error.message || 'Unknown error'

    return (
      <div
        style={{
          minHeight: '100vh',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          padding: '24px',
          boxSizing: 'border-box',
          backgroundColor: 'var(--dsw-alias-bg-base, #ffffff)',
          color: 'var(--dsw-alias-label-primary, #1f2329)',
          fontFamily: 'system-ui, -apple-system, sans-serif',
        }}
      >
        <div
          style={{
            width: '100%',
            maxWidth: '420px',
            padding: '24px',
            borderRadius: '16px',
            border: '1px solid rgba(128, 128, 128, 0.2)',
            backgroundColor: 'var(--dsw-alias-bg-layer-2, rgba(128, 128, 128, 0.08))',
          }}
        >
          <div style={{ fontSize: '17px', fontWeight: 600, marginBottom: '8px' }}>
            页面加载出现异常
          </div>
          <div
            style={{
              fontSize: '13px',
              lineHeight: '20px',
              opacity: 0.78,
              marginBottom: '16px',
              wordBreak: 'break-word',
            }}
          >
            {message}
          </div>

          {reportCode ? (
            <div
              style={{
                padding: '12px 14px',
                borderRadius: '12px',
                backgroundColor: 'rgba(77, 107, 254, 0.1)',
                marginBottom: '16px',
                fontSize: '13px',
                lineHeight: '20px',
              }}
            >
              <div style={{ fontWeight: 600, marginBottom: '4px' }}>日志已上报成功</div>
              <div>
                记录码：<strong style={{ fontFamily: 'monospace', fontSize: '15px' }}>{reportCode}</strong>
              </div>
              <div style={{ opacity: 0.75, marginTop: '4px' }}>
                请将此记录码发给开发者以便排查修复。
              </div>
            </div>
          ) : showReportForm ? (
            <div style={{ marginBottom: '16px' }}>
              <textarea
                rows={3}
                value={description}
                onChange={(e) => this.setState({ description: e.target.value })}
                placeholder="简要描述刚才的操作（选填，将自动附带报错日志与设备信息）"
                style={{
                  width: '100%',
                  boxSizing: 'border-box',
                  padding: '10px 12px',
                  borderRadius: '10px',
                  border: '1px solid rgba(128, 128, 128, 0.3)',
                  backgroundColor: 'var(--dsw-alias-bg-base, #ffffff)',
                  color: 'inherit',
                  fontSize: '13px',
                  marginBottom: '8px',
                  resize: 'vertical',
                }}
              />
              {reportError ? (
                <div style={{ color: '#e5484d', fontSize: '12px', marginBottom: '8px' }}>
                  {reportError}
                </div>
              ) : null}
              <button
                type="button"
                disabled={submitting}
                onClick={() => void this.handleSubmitReport()}
                style={{
                  padding: '8px 16px',
                  borderRadius: '999px',
                  border: 'none',
                  backgroundColor: '#18181b',
                  color: '#ffffff',
                  fontSize: '13px',
                  fontWeight: 500,
                  cursor: submitting ? 'default' : 'pointer',
                  opacity: submitting ? 0.6 : 1,
                }}
              >
                {submitting ? '正在提交…' : '确认提交日志'}
              </button>
            </div>
          ) : null}

          <div style={{ display: 'flex', gap: '10px', flexWrap: 'wrap' }}>
            <button
              type="button"
              onClick={() => window.location.reload()}
              style={{
                padding: '8px 16px',
                borderRadius: '999px',
                border: 'none',
                backgroundColor: '#4d6bfe',
                color: '#ffffff',
                fontSize: '14px',
                fontWeight: 500,
                cursor: 'pointer',
              }}
            >
              刷新重试
            </button>
            {!reportCode && !showReportForm ? (
              <button
                type="button"
                onClick={() => this.setState({ showReportForm: true })}
                style={{
                  padding: '8px 16px',
                  borderRadius: '999px',
                  border: '1px solid rgba(128, 128, 128, 0.3)',
                  backgroundColor: 'transparent',
                  color: 'inherit',
                  fontSize: '14px',
                  cursor: 'pointer',
                }}
              >
                上报错误日志
              </button>
            ) : null}
            <button
              type="button"
              onClick={() => {
                this.setState({ error: null, showReportForm: false, reportCode: null, reportError: null })
              }}
              style={{
                padding: '8px 16px',
                borderRadius: '999px',
                border: '1px solid rgba(128, 128, 128, 0.3)',
                backgroundColor: 'transparent',
                color: 'inherit',
                fontSize: '14px',
                cursor: 'pointer',
              }}
            >
              返回界面
            </button>
          </div>
        </div>
      </div>
    )
  }
}
