import { useAccount } from 'wagmi'
import { ConnectKitButton } from 'connectkit'
import { Building2, Check, ShieldAlert } from 'lucide-react'
import { useLang } from '@/lib/i18n'
import { RUN_STATUS, fmtUsdc, shortAddr, type RunData } from '@/lib/payroll'
import { Card } from '@/components/ui'
import { AnimatedUsdc } from '@/components/AnimatedUsdc'
import { UploadCard } from '@/components/admin/UploadCard'
import { WalletDirectoryCard } from '@/components/admin/WalletDirectoryCard'
import { RunsList } from '@/components/admin/RunsList'
import { TreasuryCard } from '@/components/admin/TreasuryCard'

interface Props {
  owner?: `0x${string}`
  runs: RunData[]
  paused: boolean
  totalOwed: bigint
  vaultBalance: bigint
}

export function AdminPanel({ owner, runs, paused, totalOwed, vaultBalance }: Props) {
  const { t } = useLang()
  const { address, isConnected } = useAccount()

  if (!isConnected) {
    return (
      <div className="hero mx-auto max-w-xl rounded-[28px] p-7 sm:p-9">
        <div className="absolute inset-x-0 top-0 h-1 spectral" aria-hidden />
        <div className="relative z-10">
          <div className="mb-5 flex size-12 items-center justify-center rounded-2xl" style={{ background: 'rgba(255,255,255,0.12)' }}>
            <Building2 className="size-6" aria-hidden />
          </div>
          <h2 className="display text-3xl font-bold text-balance">{t('สำหรับฝ่ายบุคคล / การเงิน', 'For HR and finance')}</h2>
          <p className="mt-3 max-w-sm text-sm text-pretty" style={{ color: 'rgba(250,247,255,0.724)' }}>
            {t('เชื่อมต่อกระเป๋าของนายจ้างเพื่ออัปโหลดข้อมูลเงินเดือนจาก SAP และจัดการ Vault', 'Connect the employer wallet to upload SAP payroll data and manage the vault.')}
          </p>
          <div className="mt-6">
            <ConnectKitButton.Custom>
              {({ show }) => (
                <button onClick={show} className="btn-light inline-flex min-h-11 items-center rounded-2xl px-5 text-sm font-semibold transition-all active:scale-[0.99]">
                  {t('เชื่อมต่อกระเป๋า', 'Connect wallet')}
                </button>
              )}
            </ConnectKitButton.Custom>
          </div>
        </div>
      </div>
    )
  }

  if (owner && address?.toLowerCase() !== owner.toLowerCase()) {
    return (
      <Card className="mx-auto max-w-md">
        <div className="flex items-start gap-3">
          <ShieldAlert className="mt-0.5 size-5 shrink-0" style={{ color: 'var(--warn)' }} aria-hidden />
          <div>
            <h2 className="display text-lg font-semibold">{t('ต้องใช้กระเป๋านายจ้าง', 'Employer wallet required')}</h2>
            <p className="mt-1 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
              {t('กระเป๋าที่เชื่อมต่ออยู่ไม่ใช่เจ้าของ Vault', 'The connected wallet is not the vault owner.')}{' '}
              <span className="mono">{shortAddr(owner)}</span>
            </p>
          </div>
        </div>
      </Card>
    )
  }

  const openRuns = runs.filter((r) => r.status === RUN_STATUS.Open).length
  const draftRuns = runs.filter((r) => r.status === RUN_STATUS.Draft).length
  const steps = [
    { n: 1, th: 'อัปโหลดจาก SAP', en: 'Upload from SAP', done: runs.length > 0 },
    { n: 2, th: 'เติมเงินและเปิดงวด', en: 'Fund and open', done: openRuns > 0 },
    { n: 3, th: 'พนักงานเคลมเอง', en: 'Employees claim', done: runs.some((r) => r.totalClaimed > 0n) },
  ]

  return (
    <div className="grid gap-5">
      <section className="hero rounded-[28px] p-6 sm:p-8">
        <div className="absolute inset-x-0 top-0 h-1 spectral" aria-hidden />
        <div className="relative z-10 grid gap-6 md:grid-cols-[1fr_auto] md:items-end">
          <div>
            <span className="text-xs font-semibold uppercase tracking-[0.1em]" style={{ color: 'rgba(250,247,255,0.72)' }}>
              {t('ยอดคงเหลือใน Vault', 'Vault balance')}
            </span>
            <div className="mt-3 flex items-baseline gap-2">
              <span className="display num text-5xl font-bold tabular-nums sm:text-6xl"><AnimatedUsdc raw={vaultBalance} /></span>
              <span className="text-lg font-medium" style={{ color: 'rgba(250,247,255,0.72)' }}>USDC</span>
            </div>
            <p className="mt-2 text-sm" style={{ color: 'rgba(250,247,255,0.72)' }}>
              {t('จองไว้จ่ายพนักงาน', 'Reserved for employees')} <span className="tabular-nums">{fmtUsdc(totalOwed)}</span> USDC · {openRuns} {t('งวดเปิด', 'open')} · {draftRuns} {t('ร่าง', 'draft')}
            </p>
          </div>
          <ol className="grid gap-2 sm:grid-cols-3 md:grid-cols-1">
            {steps.map((s) => (
              <li key={s.n} className="flex items-center gap-2.5 rounded-xl px-3 py-2 text-sm" style={{ background: 'rgba(255,255,255,0.08)' }}>
                <span
                  className="flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-bold tabular-nums"
                  style={s.done ? { background: '#8dd89f', color: '#0d1b2f' } : { background: 'rgba(255,255,255,0.16)' }}
                >
                  {s.done ? <Check className="size-3.5" aria-hidden /> : s.n}
                </span>
                {t(s.th, s.en)}
              </li>
            ))}
          </ol>
        </div>
      </section>

      <div className="grid items-start gap-5 lg:grid-cols-[1.15fr_1fr]">
        <div className="grid content-start gap-5">
          <WalletDirectoryCard />
          <UploadCard runs={runs} />
        </div>
        <div className="grid content-start gap-5">
          <TreasuryCard vaultBalance={vaultBalance} totalOwed={totalOwed} paused={paused} />
          <RunsList runs={runs} totalOwed={totalOwed} vaultBalance={vaultBalance} paused={paused} />
        </div>
      </div>
    </div>
  )
}
