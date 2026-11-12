import { AlertTriangle, Info } from 'lucide-react'
import { useLang } from '@/lib/i18n'
import { fmtUsdc, shortAddr } from '@/lib/payroll'
import type { ParsedPayroll } from '@/lib/sap'

export function PayrollPreview({ parsed }: { parsed: ParsedPayroll }) {
  const { t } = useLang()
  const errorRows = parsed.rows.filter((r) => r.errors.length > 0).length
  const converted = parsed.needsRate && parsed.entries.length > 0

  return (
    <div className="mt-5">
      {parsed.fileErrors.length > 0 && (
        <div role="alert" className="mb-3 rounded-2xl p-3.5 text-sm" style={{ background: 'rgba(186,43,76,0.08)', color: 'var(--danger)' }}>
          {parsed.fileErrors.map((m) => <div key={m}>{m}</div>)}
        </div>
      )}
      {parsed.warnings.map((m) => (
        <div key={m} className="mb-3 flex items-start gap-2 rounded-2xl p-3.5 text-xs" style={{ background: 'rgba(154,106,20,0.1)', color: 'var(--warn)' }}>
          <Info className="mt-0.5 size-4 shrink-0" aria-hidden />
          {m}
        </div>
      ))}

      {parsed.rows.length > 0 && (
        <>
          <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-4">
            <div className="inner rounded-2xl p-3">
              <div className="text-xs font-semibold" style={{ color: 'var(--subtle)' }}>{t('พนักงาน', 'Employees')}</div>
              <div className="display num text-xl font-bold tabular-nums">{parsed.entries.length}</div>
            </div>
            <div className="inner rounded-2xl p-3">
              <div className="text-xs font-semibold" style={{ color: 'var(--subtle)' }}>{t(`ยอดรวม ${parsed.currency}`, `Total ${parsed.currency}`)}</div>
              <div className="display num text-xl font-bold tabular-nums">{fmtUsdc(parsed.sourceTotal)}</div>
            </div>
            <div className="inner rounded-2xl p-3">
              <div className="text-xs font-semibold" style={{ color: 'var(--subtle)' }}>{t('จะจ่ายเป็น USDC', 'Will pay in USDC')}</div>
              <div className="display num text-xl font-bold tabular-nums">{converted || !parsed.needsRate ? fmtUsdc(parsed.total) : '—'}</div>
            </div>
            <div className="inner rounded-2xl p-3">
              <div className="text-xs font-semibold" style={{ color: 'var(--subtle)' }}>{t('แถวที่มีปัญหา', 'Rows with errors')}</div>
              <div className="display num text-xl font-bold tabular-nums" style={{ color: errorRows ? 'var(--danger)' : 'var(--success)' }}>{errorRows}</div>
            </div>
          </div>

          <div className="mt-3 max-h-72 overflow-auto rounded-2xl border" style={{ borderColor: 'var(--border)' }}>
            <table className="w-full text-left text-xs">
              <thead className="sticky top-0" style={{ background: 'var(--surface-strong)' }}>
                <tr style={{ color: 'var(--subtle)' }}>
                  <th className="px-3 py-2 font-semibold">#</th>
                  <th className="px-3 py-2 font-semibold">{t('รหัส / ชื่อ', 'ID / Name')}</th>
                  <th className="px-3 py-2 font-semibold">{t('กระเป๋า', 'Wallet')}</th>
                  <th className="px-3 py-2 text-right font-semibold">{parsed.currency}</th>
                </tr>
              </thead>
              <tbody>
                {parsed.rows.map((r) => (
                  <tr key={r.line} className="border-t align-top" style={{ borderColor: 'var(--border)' }}>
                    <td className="px-3 py-2 tabular-nums" style={{ color: 'var(--subtle)' }}>{r.line}</td>
                    <td className="px-3 py-2">
                      <div className="font-semibold">{r.employeeId || '—'}</div>
                      <div style={{ color: 'var(--muted)' }}>{r.name}</div>
                      {r.errors.map((m) => (
                        <div key={m} className="mt-0.5 flex items-center gap-1" style={{ color: 'var(--danger)' }}>
                          <AlertTriangle className="size-3 shrink-0" aria-hidden />{m}
                        </div>
                      ))}
                    </td>
                    <td className="mono px-3 py-2">{r.wallet.startsWith('0x') && r.wallet.length > 12 ? shortAddr(r.wallet) : r.wallet || '—'}</td>
                    <td className="px-3 py-2 text-right tabular-nums">{r.amountText}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="mt-2 text-xs" style={{ color: 'var(--muted)' }}>
            {parsed.skippedRows > 0 && t(`ข้ามแถวผลรวม ${parsed.skippedRows} แถว `, `Skipped ${parsed.skippedRows} total row(s). `)}
            {parsed.entries.some((e) => e.mergedLines > 1) && t('แถวของพนักงานคนเดียวกันถูกรวมเป็นยอดเดียวแล้ว', 'Multiple lines for the same employee were merged into one payment.')}
          </p>
        </>
      )}
    </div>
  )
}
