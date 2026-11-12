import { useMemo } from 'react'
import { useAccount } from 'wagmi'
import { ConnectKitButton } from 'connectkit'
import { CalendarClock, CheckCircle2, FileCheck2, Inbox, Upload, Wallet } from 'lucide-react'
import { TokenUSDC } from '@web3icons/react'
import { useMyEntries, useUsdcWalletBalance } from '@/hooks/usePayroll'
import { useNow } from '@/hooks/useNow'
import { useTx } from '@/hooks/useTx'
import { useLang } from '@/lib/i18n'
import { RUN_STATUS, VAULT_ADDRESS, fmtUsdc, isExpired, shortAddr, vaultAbi, type RunData } from '@/lib/payroll'
import { Btn, Card, Chip, TxLink } from '@/components/ui'
import { AnimatedUsdc } from '@/components/AnimatedUsdc'

interface Props {
  runs: RunData[]
  paused: boolean
  loading: boolean
}

export function EmployeePanel({ runs, paused, loading }: Props) {
  const { t, lang } = useLang()
  const { address, isConnected } = useAccount()
  const { entries, isLoading } = useMyEntries(address, runs)
  const { data: walletBalance } = useUsdcWalletBalance(address)
  const { run, stage, busy, lastHash } = useTx()
  const nowSec = useNow()

  // Employees only ever see opened payruns; drafts and cancelled runs stay private to the employer.
  const visible = useMemo(() => entries.filter((e) => e.run.status === RUN_STATUS.Open), [entries])
  const claimableEntries = visible.filter((e) => e.claimable > 0n)
  const totalClaimable = claimableEntries.reduce((sum, e) => sum + e.claimable, 0n)
  const totalClaimed = visible.filter((e) => e.claimed).reduce((sum, e) => sum + e.amount, 0n)

  if (!isConnected || !address) {
    const steps = [
      { icon: Upload, th: 'HR อัปโหลดข้อมูลเงินเดือนจาก SAP', en: 'HR uploads payroll from SAP' },
      { icon: FileCheck2, th: 'นายจ้างเติม USDC และเปิดงวด', en: 'Employer funds USDC and opens the payrun' },
      { icon: Wallet, th: 'คุณกดเคลมเข้ากระเป๋าของคุณเอง', en: 'You claim to your own wallet' },
    ]
    return (
      <div className="mx-auto grid max-w-xl gap-4">
        <div className="hero rounded-[28px] p-7 sm:p-9">
          <div className="absolute inset-x-0 top-0 h-1 spectral" aria-hidden />
          <div className="relative z-10">
            <div className="mb-5 flex size-12 items-center justify-center rounded-2xl" style={{ background: 'rgba(255,255,255,0.12)' }}>
              <Wallet className="size-6" aria-hidden />
            </div>
            <h2 className="display text-3xl font-bold text-balance sm:text-4xl">{t('เคลมเงินเดือนของคุณ', 'Claim your salary')}</h2>
            <p className="mt-3 max-w-sm text-sm text-pretty" style={{ color: 'rgba(250,247,255,0.724)' }}>
              {t('เชื่อมต่อกระเป๋าที่ HR ลงทะเบียนไว้ เพื่อดูและเคลมเงินเดือนเป็น USDC', 'Connect the wallet your HR registered to see and claim your USDC salary.')}
            </p>
            <div className="mt-6">
              <ConnectKitButton.Custom>
                {({ show }) => (
                  <Btn variant="primary" className="btn-light w-full sm:w-auto" onClick={show}>
                    <Wallet className="size-4" aria-hidden />
                    {t('เชื่อมต่อกระเป๋า', 'Connect wallet')}
                  </Btn>
                )}
              </ConnectKitButton.Custom>
            </div>
          </div>
        </div>
        <Card>
          <h3 className="display mb-4 text-base font-semibold">{t('ขั้นตอนการจ่ายเงินเดือน', 'How payroll works')}</h3>
          <ol className="grid gap-3">
            {steps.map(({ icon: Icon, th, en }, i) => (
              <li key={en} className="flex items-center gap-3">
                <span className="flex size-9 shrink-0 items-center justify-center rounded-xl" style={{ background: 'rgba(75,35,128,0.08)' }}>
                  <Icon className="size-4" aria-hidden />
                </span>
                <span className="text-sm">
                  <span className="mr-2 font-semibold tabular-nums" style={{ color: 'var(--subtle)' }}>{i + 1}</span>
                  {t(th, en)}
                </span>
              </li>
            ))}
          </ol>
        </Card>
      </div>
    )
  }

  const claimAll = () =>
    run(
      { address: VAULT_ADDRESS!, abi: vaultAbi, functionName: 'claimMany', args: [claimableEntries.slice(0, 50).map((e) => BigInt(e.run.id))] },
      t('เคลมสำเร็จ เงินเข้ากระเป๋าแล้ว', 'Claimed. Funds are in your wallet.'),
    )
  const claimOne = (id: number) =>
    run({ address: VAULT_ADDRESS!, abi: vaultAbi, functionName: 'claim', args: [BigInt(id)] }, t('เคลมสำเร็จ เงินเข้ากระเป๋าแล้ว', 'Claimed. Funds are in your wallet.'))

  const dateFmt = new Intl.DateTimeFormat(lang === 'th' ? 'th-TH' : 'en-GB', { dateStyle: 'medium' })

  return (
    <div className="mx-auto grid max-w-xl gap-4">
      <div className="hero rounded-[28px] p-6 sm:p-8">
        <div className="absolute inset-x-0 top-0 h-1 spectral" aria-hidden />
        <div className="relative z-10">
          <div className="flex items-center justify-between gap-3">
            <span className="text-xs font-semibold uppercase tracking-[0.1em]" style={{ color: 'rgba(250,247,255,0.72)' }}>
              {t('พร้อมเคลมตอนนี้', 'Ready to claim')}
            </span>
            <span className="mono rounded-full px-2.5 py-1 text-xs" style={{ background: 'rgba(255,255,255,0.1)' }}>{shortAddr(address)}</span>
          </div>
          <div className="mt-4 flex items-center gap-3">
            <span className="display num text-5xl font-bold tabular-nums sm:text-6xl">{loading || isLoading ? '…' : <AnimatedUsdc raw={totalClaimable} />}</span>
            <span className="flex items-center gap-1.5 pt-2 text-base font-medium" style={{ color: 'rgba(250,247,255,0.72)' }}>
              <TokenUSDC variant="branded" size={20} />
              USDC
            </span>
          </div>
          <p className="mt-2 text-sm" style={{ color: 'rgba(250,247,255,0.72)' }}>
            {t('เคลมแล้วทั้งหมด', 'Claimed so far')} <span className="tabular-nums">{fmtUsdc(totalClaimed)}</span> USDC
          </p>
          <Btn className="btn-light mt-6 w-full" onClick={() => void claimAll()} loading={busy} disabled={claimableEntries.length === 0 || paused}>
            {stage === 'wallet'
              ? t('ยืนยันในกระเป๋า…', 'Confirm in wallet…')
              : stage === 'confirming'
                ? t('กำลังยืนยันบนเชน…', 'Confirming…')
                : claimableEntries.length > 1
                  ? t(`เคลมทั้งหมด (${claimableEntries.length} งวด)`, `Claim all (${claimableEntries.length} payruns)`)
                  : t('เคลมเงินเดือน', 'Claim salary')}
          </Btn>
          {paused && (
            <p className="mt-3 text-sm" style={{ color: '#f0d089' }}>
              {t('การเคลมถูกพักชั่วคราวโดยฝ่ายบุคคล', 'Claims are temporarily paused by your employer.')}
            </p>
          )}
          {lastHash && (
            <div className="mt-3 [&_a]:!text-[#cbdbf2]">
              <TxLink hash={lastHash} label={t('ดูธุรกรรมล่าสุดบน ArcScan', 'View latest transaction on ArcScan')} />
            </div>
          )}
        </div>
      </div>

      {walletBalance !== undefined && walletBalance === 0n && (
        <p className="rounded-2xl px-4 py-3 text-sm text-pretty" style={{ background: 'rgba(154,106,20,0.1)', color: 'var(--warn)' }}>
          {t(
            'บน Arc ค่าแก๊สจ่ายเป็น USDC กระเป๋านี้ยังไม่มี USDC สำหรับค่าธรรมเนียม ใช้ปุ่ม Get test USDC ในแถบด้านข้างของ Arc Studio',
            'On Arc, gas is paid in USDC and this wallet holds none. Use "Get test USDC" in the Arc Studio sidebar to cover the fee.',
          )}
        </p>
      )}

      <Card>
        <h3 className="display mb-4 text-lg font-semibold">{t('สลิปเงินเดือน', 'Payslips')}</h3>
        {isLoading || loading ? (
          <div className="h-20 animate-pulse rounded-2xl" style={{ background: 'var(--surface-muted)' }} />
        ) : visible.length === 0 ? (
          <div className="flex flex-col items-center rounded-2xl px-5 py-8 text-center inner">
            <Inbox className="mb-3 size-8" style={{ color: 'var(--subtle)' }} aria-hidden />
            <p className="max-w-xs text-sm text-pretty" style={{ color: 'var(--muted)' }}>
              {t('ยังไม่มีเงินเดือนสำหรับกระเป๋านี้ หากคาดว่าควรมี ให้ตรวจสอบกับ HR ว่าใช้ที่อยู่กระเป๋าเดียวกันนี้', 'No salary for this wallet yet. If you expect one, confirm with HR that this exact wallet address was registered.')}
            </p>
          </div>
        ) : (
          <ul className="grid gap-2.5">
            {visible.map((e) => {
              const expired = e.run.expiredReleased || isExpired(e.run, nowSec, paused)
              const status = e.claimed ? 'claimed' : e.revoked ? 'revoked' : expired ? 'expired' : paused ? 'paused' : 'claimable'
              return (
                <li key={e.run.id} className="inner flex items-center justify-between gap-3 rounded-2xl p-4">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-semibold">{e.run.label || `Payrun #${e.run.id}`}</div>
                    <div className="mt-1.5 flex flex-wrap items-center gap-2">
                      {status === 'claimed' && <Chip tone="success"><CheckCircle2 className="mr-1 size-3" aria-hidden />{t('เคลมแล้ว', 'Claimed')}</Chip>}
                      {status === 'claimable' && <Chip tone="success">{t('พร้อมเคลม', 'Ready')}</Chip>}
                      {status === 'paused' && <Chip tone="warn">{t('พักชั่วคราว', 'Paused')}</Chip>}
                      {status === 'expired' && <Chip tone="danger">{t('หมดเวลาเคลม', 'Expired')}</Chip>}
                      {status === 'revoked' && <Chip tone="danger">{t('ยกเลิกโดยนายจ้าง', 'Revoked')}</Chip>}
                      {e.run.claimDeadline !== 0 && status === 'claimable' && (
                        <span className="inline-flex items-center gap-1 text-xs" style={{ color: 'var(--muted)' }}>
                          <CalendarClock className="size-3" aria-hidden />
                          {t('เคลมภายใน', 'Claim by')} {dateFmt.format(new Date(e.run.claimDeadline * 1000))}
                        </span>
                      )}
                    </div>
                  </div>
                  <div className="flex shrink-0 flex-col items-end gap-2">
                    <div className="display num text-xl font-bold tabular-nums">{fmtUsdc(e.amount)}</div>
                    {status === 'claimable' && (
                      <Btn size="sm" variant="ghost" onClick={() => void claimOne(e.run.id)} disabled={busy}>
                        {t('เคลม', 'Claim')}
                      </Btn>
                    )}
                  </div>
                </li>
              )
            })}
          </ul>
        )}
        <p className="mt-4 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
          {t('เงินจะถูกส่งตรงเข้ากระเป๋าที่เชื่อมต่อเท่านั้น', 'Funds are always sent to the connected wallet only.')}
        </p>
      </Card>
    </div>
  )
}
