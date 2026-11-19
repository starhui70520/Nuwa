import { useCallback, useEffect, useState } from 'react';
import type { IssueReportDetail, IssueReportSummary, ReportStatus } from '../types';
import { formatDate } from '../utils';

interface AdminReportsTabProps {
  token: string;
  onUnauthorized: () => void;
  onNotify: (msg: string) => void;
  onCountChange?: (count: number) => void;
}

export function AdminReportsTab({
  token,
  onUnauthorized,
  onNotify,
  onCountChange
}: AdminReportsTabProps) {
  const [reports, setReports] = useState<IssueReportSummary[]>([]);
  const [loading, setLoading] = useState(false);
  const [query, setQuery] = useState('');
  const [statusFilter, setStatusFilter] = useState<'all' | ReportStatus>('all');

  const [selected, setSelected] = useState<IssueReportDetail | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);
  const [adminNote, setAdminNote] = useState('');
  const [saving, setSaving] = useState(false);

  const loadReports = useCallback(
    async (q = query, status = statusFilter) => {
      if (!token) return;
      setLoading(true);
      try {
        const params = new URLSearchParams();
        if (q.trim()) params.set('q', q.trim());
        if (status !== 'all') params.set('status', status);
        const url = `/api/admin/reports${params.toString() ? `?${params.toString()}` : ''}`;
        const res = await fetch(url, {
          headers: { Authorization: `Bearer ${token}` }
        });
        if (res.status === 401) {
          onUnauthorized();
          return;
        }
        const json = (await res.json()) as { reports?: IssueReportSummary[] };
        const list = json.reports || [];
        setReports(list);
        if (!q.trim() && status === 'all') {
          onCountChange?.(list.length);
        }
      } finally {
        setLoading(false);
      }
    },
    [onCountChange, onUnauthorized, query, statusFilter, token]
  );

  useEffect(() => {
    void loadReports();
  }, [loadReports]);

  const openDetail = async (code: string) => {
    setLoadingDetail(true);
    try {
      const res = await fetch(`/api/admin/reports/${encodeURIComponent(code)}`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      if (res.status === 401) {
        onUnauthorized();
        return;
      }
      if (!res.ok) {
        onNotify(`未找到记录码 ${code}`);
        return;
      }
      const json = (await res.json()) as { report: IssueReportDetail };
      setSelected(json.report);
      setAdminNote(json.report.adminNote || '');
    } finally {
      setLoadingDetail(false);
    }
  };

  const handlePatch = async (code: string, patch: { status?: ReportStatus; adminNote?: string }) => {
    setSaving(true);
    try {
      const res = await fetch(`/api/admin/reports/${encodeURIComponent(code)}`, {
        method: 'PATCH',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(patch)
      });
      if (res.status === 401) {
        onUnauthorized();
        return;
      }
      const json = (await res.json()) as { report?: IssueReportDetail; error?: string };
      if (!res.ok || !json.report) {
        onNotify(json.error || '更新失败');
        return;
      }
      setSelected(json.report);
      setAdminNote(json.report.adminNote || '');
      onNotify(`已更新记录 ${code}`);
      await loadReports();
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (code: string) => {
    if (!window.confirm(`确认删除日志记录 ${code}？此操作不可恢复。`)) return;
    const res = await fetch(`/api/admin/reports/${encodeURIComponent(code)}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` }
    });
    if (res.status === 401) {
      onUnauthorized();
      return;
    }
    if (res.ok) {
      if (selected?.code === code) {
        setSelected(null);
      }
      onNotify(`已删除记录 ${code}`);
      await loadReports();
    }
  };

  const handleCopyJson = async () => {
    if (!selected) return;
    try {
      await navigator.clipboard.writeText(JSON.stringify(selected, null, 2));
      onNotify(`已复制 ${selected.code} 完整日志 JSON`);
    } catch {
      onNotify('复制失败，请手动复制');
    }
  };

  return (
    <div className="space-y-6">
      {/* Search & Filter Bar */}
      <div className="rounded-[18px] border border-[#e8e8e8] bg-white p-[24px]">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <p className="eyebrow">ISSUE REPORTS</p>
            <h2 className="mt-1.5 text-[23px] font-medium text-[#18181b]">应用问题与日志收集</h2>
          </div>

          <div className="flex flex-wrap items-center gap-2.5">
            <input
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  const trimmed = query.trim().toUpperCase();
                  if (/^NW-[A-Z0-9]{4,}$/.test(trimmed)) {
                    void openDetail(trimmed);
                  } else {
                    void loadReports(query, statusFilter);
                  }
                }
              }}
              placeholder="输入记录码 (如 NW-XXXXXX) 或关键词"
              className="w-[260px] max-w-full h-[38px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[13px] text-[#18181b] outline-none"
            />
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value as 'all' | ReportStatus)}
              className="h-[38px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[13px] text-[#18181b] outline-none"
            >
              <option value="all">全部状态</option>
              <option value="open">待处理</option>
              <option value="resolved">已修复</option>
            </select>
            <button
              type="button"
              onClick={() => void loadReports(query, statusFilter)}
              className="rc-pill-soft !min-h-[38px] !px-4 !text-[13px]"
            >
              {loading ? '查询中…' : '查询'}
            </button>
          </div>
        </div>

        {/* Table */}
        <div className="mt-5 overflow-x-auto">
          {reports.length === 0 ? (
            <p className="py-10 text-center text-[14px] text-[#686d74]">
              {loading ? '正在加载问题日志…' : '暂无用户上报的问题记录'}
            </p>
          ) : (
            <table className="w-full text-left text-[13px] border-collapse">
              <thead>
                <tr className="border-b border-[#e8e8e8] text-[#686d74]">
                  <th className="py-3 pr-4 font-medium">记录码</th>
                  <th className="py-3 pr-4 font-medium">问题类型</th>
                  <th className="py-3 pr-4 font-medium">问题描述</th>
                  <th className="py-3 pr-4 font-medium">版本 / 平台</th>
                  <th className="py-3 pr-4 font-medium">日志数</th>
                  <th className="py-3 pr-4 font-medium">状态</th>
                  <th className="py-3 pr-4 font-medium">提交时间</th>
                  <th className="py-3 text-right font-medium">操作</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-[#e8e8e8]">
                {reports.map((item) => (
                  <tr
                    key={item.code}
                    className={selected?.code === item.code ? 'bg-[#f6f6f6]' : undefined}
                  >
                    <td className="py-3.5 pr-4 font-mono font-medium text-[#18181b]">
                      {item.code}
                    </td>
                    <td className="py-3.5 pr-4 text-[#18181b] whitespace-nowrap">
                      {item.issueType}
                    </td>
                    <td className="py-3.5 pr-4 text-[#5d6168] max-w-[300px] truncate">
                      {item.description}
                    </td>
                    <td className="py-3.5 pr-4 font-mono text-[#5d6168] whitespace-nowrap">
                      {item.appVersion ? `v${item.appVersion}` : '—'} · {item.platform || '—'}
                    </td>
                    <td className="py-3.5 pr-4 font-mono text-[#18181b]">{item.logCount}</td>
                    <td className="py-3.5 pr-4 whitespace-nowrap">
                      <span className={item.status === 'resolved' ? 'rc-tag' : 'rc-tag-dark'}>
                        {item.status === 'resolved' ? '已修复' : '待处理'}
                      </span>
                    </td>
                    <td className="py-3.5 pr-4 font-mono text-[#686d74] whitespace-nowrap">
                      {formatDate(item.createdAt)}
                    </td>
                    <td className="py-3.5 text-right whitespace-nowrap">
                      <div className="inline-flex items-center gap-3">
                        <button
                          type="button"
                          onClick={() => void openDetail(item.code)}
                          className="text-[#18181b] font-medium hover:opacity-55 cursor-pointer"
                        >
                          查看详情
                        </button>
                        <button
                          type="button"
                          onClick={() => void handleDelete(item.code)}
                          className="text-[#d83a36] hover:opacity-65 cursor-pointer"
                        >
                          删除
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {/* Selected Report Detail */}
      {loadingDetail && (
        <div className="rounded-[18px] border border-[#e8e8e8] bg-white p-[28px] text-[14px] text-[#686d74]">
          正在加载日志详情…
        </div>
      )}

      {selected && !loadingDetail && (
        <div className="rounded-[18px] border border-[#18181b] bg-white p-[28px] space-y-6">
          <div className="flex flex-wrap items-start justify-between gap-4 border-b border-[#e8e8e8] pb-5">
            <div>
              <div className="flex items-center gap-2.5">
                <h3 className="text-[22px] font-mono font-medium text-[#18181b] m-0">
                  {selected.code}
                </h3>
                <span className={selected.status === 'resolved' ? 'rc-tag' : 'rc-tag-dark'}>
                  {selected.status === 'resolved' ? '已修复' : '待处理'}
                </span>
                <span className="rc-tag">{selected.issueType}</span>
              </div>
              <p className="mt-2 text-[13px] text-[#686d74]">
                提交时间：{formatDate(selected.createdAt)}
                {selected.clientIp ? ` · IP: ${selected.clientIp}` : ''}
                {selected.contact ? ` · 联系方式: ${selected.contact}` : ''}
              </p>
            </div>

            <div className="flex flex-wrap items-center gap-2.5">
              <button
                type="button"
                onClick={() => void handleCopyJson()}
                className="rc-pill-soft !min-h-[36px] !px-4 !text-[13px]"
              >
                复制完整 JSON
              </button>
              <button
                type="button"
                disabled={saving}
                onClick={() =>
                  void handlePatch(selected.code, {
                    status: selected.status === 'resolved' ? 'open' : 'resolved'
                  })
                }
                className="rc-pill-dark !min-h-[36px] !px-4 !text-[13px]"
              >
                {selected.status === 'resolved' ? '重新标记待处理' : '标记已修复'}
              </button>
              <button
                type="button"
                onClick={() => setSelected(null)}
                className="rc-pill-soft !min-h-[36px] !px-4 !text-[13px]"
              >
                关闭
              </button>
            </div>
          </div>

          {/* Description */}
          <div>
            <p className="text-[12px] font-medium text-[#686d74] mb-2">用户问题描述</p>
            <div className="rounded-[12px] bg-[#f6f6f6] p-4 text-[14px] leading-[1.7] text-[#18181b] whitespace-pre-wrap">
              {selected.description}
            </div>
          </div>

          {/* Device Info */}
          <div>
            <p className="text-[12px] font-medium text-[#686d74] mb-2">设备与运行环境信息</p>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 rounded-[12px] border border-[#e8e8e8] p-4 text-[13px]">
              <div>
                <span className="text-[#686d74]">App 版本：</span>
                <span className="font-mono text-[#18181b]">
                  {selected.deviceInfo.appVersion || '—'}
                </span>
              </div>
              <div>
                <span className="text-[#686d74]">平台：</span>
                <span className="font-mono text-[#18181b]">
                  {selected.deviceInfo.platform || '—'}
                </span>
              </div>
              <div>
                <span className="text-[#686d74]">屏幕 / 视口：</span>
                <span className="font-mono text-[#18181b]">
                  {selected.deviceInfo.screen || '—'} / {selected.deviceInfo.viewport || '—'}
                </span>
              </div>
              <div>
                <span className="text-[#686d74]">语言 / 时区：</span>
                <span className="font-mono text-[#18181b]">
                  {selected.deviceInfo.language || '—'} · {selected.deviceInfo.timezone || '—'}
                </span>
              </div>
              <div>
                <span className="text-[#686d74]">接口模式：</span>
                <span className="font-mono text-[#18181b]">
                  {selected.deviceInfo.authMode || '—'} / {selected.deviceInfo.apiProtocol || '—'}
                </span>
              </div>
              <div>
                <span className="text-[#686d74]">网络在线：</span>
                <span className="font-mono text-[#18181b]">
                  {selected.deviceInfo.online === undefined
                    ? '—'
                    : selected.deviceInfo.online
                      ? '是'
                      : '否'}
                </span>
              </div>
              <div className="sm:col-span-2 lg:col-span-3 break-all">
                <span className="text-[#686d74]">User-Agent：</span>
                <span className="font-mono text-[12px] text-[#5d6168]">
                  {selected.deviceInfo.userAgent || '—'}
                </span>
              </div>
            </div>
          </div>

          {/* Admin Note */}
          <div>
            <p className="text-[12px] font-medium text-[#686d74] mb-2">排查备注</p>
            <div className="flex flex-col sm:flex-row gap-2.5">
              <input
                type="text"
                value={adminNote}
                onChange={(e) => setAdminNote(e.target.value)}
                placeholder="记录排查结论或修复版本号，如：已在 v0.1.19 修复"
                className="flex-1 h-[40px] rounded-[10px] border border-[#e8e8e8] bg-[#f6f6f6] focus:bg-white focus:border-[#18181b] px-3 text-[13px] text-[#18181b] outline-none"
              />
              <button
                type="button"
                disabled={saving}
                onClick={() => void handlePatch(selected.code, { adminNote })}
                className="rc-pill-soft !min-h-[40px] !px-5 !text-[13px]"
              >
                保存备注
              </button>
            </div>
          </div>

          {/* Logs */}
          <div>
            <p className="text-[12px] font-medium text-[#686d74] mb-2">
              运行与报错日志（共 {selected.logs.length} 条）
            </p>
            {selected.logs.length === 0 ? (
              <p className="text-[13px] text-[#686d74]">本次提交未附带运行日志。</p>
            ) : (
              <div className="max-h-[420px] overflow-y-auto rounded-[12px] bg-[#18181b] text-[#e4e4e7] p-4 font-mono text-[12px] space-y-2.5">
                {selected.logs.map((entry, idx) => (
                  <div key={`${entry.ts}-${idx}`} className="border-b border-white/10 pb-2 last:border-b-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-[#a1a1aa]">{entry.ts}</span>
                      <span
                        className={
                          entry.level === 'error'
                            ? 'text-[#f87171] font-semibold'
                            : entry.level === 'warn'
                              ? 'text-[#fbbf24] font-semibold'
                              : 'text-[#60a5fa]'
                        }
                      >
                        [{entry.level.toUpperCase()}]
                      </span>
                      <span className="text-[#d4d4d8]">[{entry.source}]</span>
                      <span className="text-white break-all">{entry.message}</span>
                    </div>
                    {entry.detail && (
                      <pre className="mt-1.5 pl-3 text-[11px] text-[#a1a1aa] whitespace-pre-wrap break-all m-0">
                        {entry.detail}
                      </pre>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
