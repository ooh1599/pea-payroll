import { ConnectKitButton } from 'connectkit'
import { TokenUSDC } from '@web3icons/react'
import { BRAND } from '@/brand'
import { Logo } from '@/components/Logo'
import { useLang } from '@/lib/i18n'

export function Header() {
  const { lang, setLang, t } = useLang()
  return (
    <header
      className="sticky top-0 z-30 border-b"
      style={{ background: 'rgba(255,255,255,0.78)', borderColor: 'var(--border)', backdropFilter: 'blur(20px) saturate(180%)', WebkitBackdropFilter: 'blur(20px) saturate(180%)' }}
    >
      <div className="spectral h-1 w-full" aria-hidden />
      <div className="mx-auto flex w-full max-w-5xl items-center justify-between gap-3 px-4 py-3">
        <div className="flex min-w-0 items-center gap-3">
          <Logo size={44} />
          <div className="min-w-0">
            <div className="display truncate text-base font-bold leading-tight sm:text-lg">{t(BRAND.nameTh, BRAND.nameEn)}</div>
            <div className="mt-1 hidden items-center gap-1.5 text-xs sm:flex" style={{ color: 'var(--muted)' }}>
              <TokenUSDC variant="branded" size={14} />
              {t('ระบบจ่ายเงินเดือน USDC · Arc Testnet', 'USDC Payroll Vault · Arc Testnet')}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <div className="flex rounded-full border p-0.5 text-xs font-semibold" style={{ borderColor: 'var(--border)', background: 'var(--surface-muted)' }} role="group" aria-label="Language">
            {(['th', 'en'] as const).map((l) => (
              <button
                key={l}
                onClick={() => setLang(l)}
                aria-pressed={lang === l}
                className="min-h-9 min-w-11 rounded-full px-3 transition-colors"
                style={lang === l ? { background: 'var(--accent)', color: '#fff' } : { color: 'var(--ink-2)' }}
              >
                {l.toUpperCase()}
              </button>
            ))}
          </div>
          <ConnectKitButton showBalance={false} />
        </div>
      </div>
    </header>
  )
}
