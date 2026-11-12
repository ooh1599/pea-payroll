import { useState } from 'react'
import { isAddress } from 'viem'
import { ClipboardList, UserMinus } from 'lucide-react'
import { useFunding } from '@/hooks/useFunding'
import { useNow } from '@/hooks/useNow'
import { useLang } from '@/lib/i18n'
import { RUN_STATUS, VAULT_ADDRESS, fmtUsdc, isExpired, isUploadComplete, unclaimedOf, vaultAbi, type RunData } from '@/lib/payroll'
import { Btn, Card, Chip, SectionTitle, TxLink, inputClass } from '@/components/ui'

interface Props {
  runs: RunData[]
  totalOwed: bigint
  vaultBalance: bigint
  paused: boolean
}

export function RunsList({ runs, totalOwed, vaultBalance, paused }: Props) {
  const { t, lang } = useLang()
  const { fundVault, run, busy, stage, lastHash } = useFunding()
  const [revokeFor, setRevokeFor] = useState<number | null>(null)
  const [revokeWallet, setRevokeWallet] = useState('')
  const nowSec = useNow()
  const dateFmt = new Intl.DateTimeFormat(lang === 'th' ? 'th-TH' : 'en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZoneName: 'short' })

  const call = (functionName: 'openPayrun' | 'cancelPayrun' | 'reclaimExpired', id: number, message: string) =>
    run({ address: VAULT_ADDRESS!, abi: vaultAbi, functionName, args: [BigInt(id)] }, message)

  const fundAndOpen = async (r: RunData) => {
    const needed = totalOwed + unclaimedOf(r)
    const shortfall = needed > vaultBalance ? needed - vaultBalance : 0n
    if (!(await fundVault(shortfall))) return
    await call('openPayrun', r.id, t('เปิดงวดแล้ว พนักงานเคลมได้ทันที', 'Payrun opened. Employees can claim now.'))
  }

  const revoke = async (id: number) => {
    if (!isAddress(revokeWallet)) return
    const ok = await run(
      { address: VAULT_ADDRESS!, abi: vaultAbi, functionName: 'revokeEntry', args: [BigInt(id), revokeWallet] },
      t('ยกเลิกรายการแล้ว', 'Entry revoked.'),
    )
    if (ok) {
      setRevokeFor(null)
      setRevokeWallet('')
    }
  }

  const label = stage === 'wallet' ? t('ยืนยันในกระเป๋า…', 'Confirm in wallet…') : stage === 'confirming' ? t('กำลังยืนยัน…', 'Confirming…') : null

  return (
    <Card>
      <SectionTitle
        icon={<ClipboardList className="size-4" aria-hidden />}
        title={t('2. เติมเงินและเปิดงวด', '2. Fund and open payruns')}
        hint={t(
          'งวดสถานะร่างยังเคลมไม่ได้ เมื่อเติมเงินครบและเปิดงวด พนักงานจึงเคลมได้เอง',
          'Draft payruns cannot be claimed. Once fully funded and opened, employees claim for themselves.',
        )}
      />
      {runs.length === 0 ? (
        <div className="inner rounded-2xl p-5 text-center text-sm" style={{ color: 'var(--muted)' }}>
          {t('ยังไม่มีงวดเงินเดือน อัปโหลดไฟล์จาก SAP เพื่อเริ่มต้น', 'No payruns yet. Upload a SAP file to get started.')}
        </div>
      ) : (
        <ul className="grid gap-3">
          {runs.map((r) => {
            const base = r.totalAllocated - r.totalRevoked
            const pct = base > 0n ? Number((r.totalClaimed * 100n) / base) : 0
            const expired = r.status === RUN_STATUS.Open && isExpired(r, nowSec, paused)
            const complete = isUploadComplete(r)
            const needed = totalOwed + unclaimedOf(r)
            const shortfall = needed > vaultBalance ? needed - vaultBalance : 0n
            return (
              <li key={r.id} className="inner rounded-2xl p-4">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-semibold">#{r.id} · {r.label || '—'}</div>
                    <div className="mt-1 text-xs" style={{ color: 'var(--muted)' }}>
                      {r.entryCount} {t('คน', 'employees')} ·{' '}
                      {r.claimDeadline === 0 ? t('ไม่จำกัดเวลาเคลม', 'No claim deadline') : `${t('เคลมภายใน', 'Claim by')} ${dateFmt.format(new Date(r.claimDeadline * 1000))}`}
                    </div>
                  </div>
                  <div className="flex gap-1.5">
                    {r.status === RUN_STATUS.Draft && <Chip tone="warn">{complete ? t('ร่าง', 'Draft') : t('อัปโหลดยังไม่ครบ', 'Upload incomplete')}</Chip>}
                    {r.status === RUN_STATUS.Open && !expired && <Chip tone="success">{t('เปิดให้เคลม', 'Open')}</Chip>}
                    {expired && <Chip tone="danger">{r.expiredReleased ? t('หมดเวลา (คืนวงเงินแล้ว)', 'Expired (released)') : t('หมดเวลา', 'Expired')}</Chip>}
                    {r.status === RUN_STATUS.Cancelled && <Chip tone="neutral">{t('ยกเลิก', 'Cancelled')}</Chip>}
                  </div>
                </div>

                <div className="mt-3 flex items-baseline justify-between text-xs">
                  <span style={{ color: 'var(--muted)' }}>{t('เคลมแล้ว', 'Claimed')}</span>
                  <span className="tabular-nums"><b>{fmtUsdc(r.totalClaimed)}</b> / {fmtUsdc(base)} USDC</span>
                </div>
                <div className="mt-1.5 h-1.5 overflow-hidden rounded-full" style={{ background: 'rgba(75,35,128,0.1)' }}>
                  <div className="h-full rounded-full" style={{ width: `${pct}%`, background: 'var(--success)' }} />
                </div>

                {r.status === RUN_STATUS.Draft && !complete && (
                  <p className="mt-3 text-xs text-pretty" style={{ color: 'var(--warn)' }}>
                    {t(
                      `อัปโหลดแล้ว ${r.entryCount}/${r.expectedEntryCount} คน อัปโหลดไฟล์เดิมอีกครั้งด้วยรหัสเดียวกันเพื่อทำต่อ`,
                      `${r.entryCount}/${r.expectedEntryCount} employees uploaded. Upload the same file again with the same ID to continue.`,
                    )}
                  </p>
                )}
                {r.status === RUN_STATUS.Open && (
                  <p className="mt-3 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
                    {t('งวดที่เปิดแล้วยกเลิกรายบุคคลไม่ได้ หากผิดพลาดให้สร้างงวดใหม่เพื่อปรับปรุง', 'Opened payruns cannot be revoked per employee. Issue a new payrun to correct mistakes.')}
                  </p>
                )}

                <div className="mt-3 flex flex-wrap gap-2">
                  {r.status === RUN_STATUS.Draft && (
                    <>
                      <Btn size="sm" onClick={() => void fundAndOpen(r)} loading={busy} disabled={!complete}>
                        {label ??
                          (shortfall > 0n
                            ? t(`เติม ${fmtUsdc(shortfall)} USDC และเปิดงวด`, `Fund ${fmtUsdc(shortfall)} USDC and open`)
                            : t('เปิดงวด', 'Open payrun'))}
                      </Btn>
                      <Btn size="sm" variant="danger" onClick={() => void call('cancelPayrun', r.id, t('ยกเลิกงวดแล้ว', 'Payrun cancelled.'))} disabled={busy}>
                        {t('ยกเลิกร่าง', 'Cancel draft')}
                      </Btn>
                    </>
                  )}
                  {expired && !r.expiredReleased && (
                    <Btn size="sm" variant="ghost" onClick={() => void call('reclaimExpired', r.id, t('คืนวงเงินที่หมดเวลาแล้ว', 'Expired amount released.'))} disabled={busy}>
                      {t('คืนวงเงินที่เคลมไม่ทัน', 'Release unclaimed amount')}
                    </Btn>
                  )}
                  {r.status === RUN_STATUS.Draft && (
                    <Btn size="sm" variant="ghost" onClick={() => setRevokeFor(revokeFor === r.id ? null : r.id)}>
                      <UserMinus className="size-3.5" aria-hidden />
                      {t('ยกเลิกรายบุคคล', 'Revoke an employee')}
                    </Btn>
                  )}
                </div>

                {revokeFor === r.id && (
                  <div className="mt-3 flex flex-wrap gap-2">
                    <input className={`${inputClass} mono flex-1`} placeholder="0x…" value={revokeWallet} onChange={(e) => setRevokeWallet(e.target.value.trim())} aria-label={t('กระเป๋าพนักงาน', 'Employee wallet')} />
                    <Btn size="sm" variant="danger" onClick={() => void revoke(r.id)} disabled={!isAddress(revokeWallet) || busy}>
                      {t('ยืนยันยกเลิก', 'Revoke')}
                    </Btn>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}
      {lastHash && <div className="mt-3"><TxLink hash={lastHash} label={t('ธุรกรรมล่าสุดบน ArcScan', 'Latest transaction on ArcScan')} /></div>}
    </Card>
  )
}
