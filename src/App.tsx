import { useState } from 'react'
import { useAccount } from 'wagmi'
import { AnimatePresence, motion } from 'framer-motion'
import { Building2, ExternalLink, ShieldCheck, User } from 'lucide-react'
import { Header } from '@/components/Header'
import { EmployeePanel } from '@/components/EmployeePanel'
import { AdminPanel } from '@/components/admin/AdminPanel'
import { Card } from '@/components/ui'
import { useVault } from '@/hooks/usePayroll'
import { LangProvider, useLang } from '@/lib/i18n'
import { CHAIN_ID, VAULT_ADDRESS } from '@/lib/payroll'
import { buildAddressExplorerUrl } from '@/onchain-facts'

type Tab = 'employee' | 'employer'

function Footer() {
  const { t } = useLang()
  return (
    <footer className="mx-auto mt-12 flex w-full max-w-5xl flex-wrap items-center justify-between gap-3 px-4 text-xs" style={{ color: 'var(--muted)' }}>
      <span className="inline-flex items-center gap-2">
        <ShieldCheck className="size-4" aria-hidden />
        {t('เงินเดือนอยู่ในสัญญาอัจฉริยะ ถอนเข้ากระเป๋าพนักงานเท่านั้น นายจ้างแนะนำให้ใช้ multisig เป็นเจ้าของ', 'Salaries are held by a smart contract and can only be paid to the employee wallet. Employers should use a multisig as owner.')}
      </span>
      {VAULT_ADDRESS && (
        <a
          href={buildAddressExplorerUrl(CHAIN_ID, VAULT_ADDRESS)}
          target="_blank"
          rel="noreferrer noopener"
          className="inline-flex items-center gap-1 font-semibold"
          style={{ color: 'var(--accent-hover)' }}
        >
          {t('ดูสัญญาบน ArcScan', 'View contract on ArcScan')}
          <ExternalLink className="size-3" aria-hidden />
        </a>
      )}
    </footer>
  )
}

function Shell() {
  const { t } = useLang()
  const { address } = useAccount()
  const vault = useVault()
  const [chosen, setChosen] = useState<Tab | null>(null)

  const isOwner = Boolean(address && vault.owner && address.toLowerCase() === vault.owner.toLowerCase())
  const tab: Tab = chosen ?? (isOwner ? 'employer' : 'employee')

  const tabs: { id: Tab; label: string; icon: typeof User }[] = [
    { id: 'employee', label: t('พนักงาน', 'Employee'), icon: User },
    { id: 'employer', label: t('นายจ้าง / HR', 'Employer / HR'), icon: Building2 },
  ]

  return (
    <div className="canvas min-h-dvh pb-24">
      <Header />
      <main className="mx-auto mt-8 w-full max-w-5xl px-4">
        {!VAULT_ADDRESS ? (
          <Card className="mx-auto max-w-md text-center">
            <h2 className="display text-xl font-bold">{t('ยังไม่ได้ติดตั้งสัญญา', 'Contract not deployed yet')}</h2>
            <p className="mt-2 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
              {t('ตั้งค่า VITE_PAYROLL_VAULT_ADDRESS ใน .env หลังติดตั้งสัญญา PayrollVault', 'Set VITE_PAYROLL_VAULT_ADDRESS in .env after deploying the PayrollVault contract.')}
            </p>
          </Card>
        ) : (
          <>
            <div className="glass mx-auto mb-8 flex w-fit rounded-full p-1" role="tablist" aria-label={t('มุมมอง', 'View')}>
              {tabs.map(({ id, label, icon: Icon }) => (
                <button
                  key={id}
                  role="tab"
                  aria-selected={tab === id}
                  onClick={() => setChosen(id)}
                  className="relative inline-flex min-h-11 items-center gap-2 rounded-full px-5 text-sm font-semibold"
                  style={{ color: tab === id ? '#fff' : 'var(--ink-2)' }}
                >
                  {tab === id && (
                    <motion.span
                      layoutId="tab-pill"
                      className="absolute inset-0 rounded-full"
                      style={{ background: 'var(--accent)' }}
                      transition={{ type: 'spring', stiffness: 420, damping: 34 }}
                    />
                  )}
                  <span className="relative z-10 inline-flex items-center gap-2">
                    <Icon className="size-4" aria-hidden />
                    {label}
                  </span>
                </button>
              ))}
            </div>
            {vault.isError && (
              <p role="alert" className="mb-4 text-center text-sm" style={{ color: 'var(--danger)' }}>
                {t('อ่านข้อมูลจากเชนไม่ได้ ลองรีเฟรช', 'Could not read from the chain. Try refreshing.')}
              </p>
            )}
            <AnimatePresence mode="wait">
              <motion.div
                key={tab}
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -6 }}
                transition={{ duration: 0.18 }}
              >
                {tab === 'employee' ? (
                  <EmployeePanel runs={vault.runs} paused={Boolean(vault.paused)} loading={vault.isLoading} />
                ) : (
                  <AdminPanel
                    owner={vault.owner}
                    runs={vault.runs}
                    paused={Boolean(vault.paused)}
                    totalOwed={vault.totalOwed ?? 0n}
                    vaultBalance={vault.vaultBalance ?? 0n}
                  />
                )}
              </motion.div>
            </AnimatePresence>
          </>
        )}
      </main>
      <Footer />
    </div>
  )
}

export default function App() {
  return (
    <LangProvider>
      <Shell />
    </LangProvider>
  )
}
