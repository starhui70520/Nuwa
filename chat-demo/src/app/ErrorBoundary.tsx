import { Component, type ReactNode } from 'react'

type ErrorBoundaryProps = {
  children: ReactNode
}

type ErrorBoundaryState = {
  error: Error | null
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  override state: ErrorBoundaryState = { error: null }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error }
  }

  override render(): ReactNode {
    if (!this.state.error) {
      return this.props.children
    }

    const message = this.state.error.message || 'Unknown error'
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
            maxWidth: '400px',
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
            <button
              type="button"
              onClick={() => {
                this.setState({ error: null })
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
