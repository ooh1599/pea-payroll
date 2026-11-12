import type { ButtonHTMLAttributes, ReactNode } from 'react'
import { ExternalLink, Loader2 } from 'lucide-react'
import { buildTxExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID } from '@/lib/payroll'

type Variant = 'primary' | 'ghost' | 'danger'

interface BtnProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant
  loading?: boolean
  size?: 'md' | 'sm'
}

export function Btn({ variant = 'primary', loading, size = 'md', className = '', children, disabled, ...rest }: BtnProps) {
  const base = 'inline-flex items-center justify-center gap-2 rounded-2xl font-semibold transition-all active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-40'
  const sizing = size === 'md' ? 'min-h-11 px-5 text-sm' : 'min-h-9 px-3.5 text-xs'
  const tone =
    variant === 'primary' ? 'btn-primary' : variant === 'danger' ? 'border text-[var(--danger)] bg-white/70 hover:bg-white' : 'btn-ghost'
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={`${base} ${sizing} ${tone} ${className}`}
      style={variant === 'danger' ? { borderColor: 'rgba(186,43,76,0.3)' } : undefined}
    >
      {loading && <Loader2 className="size-4 animate-spin" aria-hidden />}
      {children}
    </button>
  )
}

type Tone = 'success' | 'warn' | 'danger' | 'neutral'

export function Chip({ tone = 'neutral', children }: { tone?: Tone; children: ReactNode }) {
  const palette: Record<Tone, { bg: string; fg: string }> = {
    success: { bg: 'rgba(26,128,71,0.12)', fg: 'var(--success)' },
    warn: { bg: 'rgba(154,106,20,0.14)', fg: 'var(--warn)' },
    danger: { bg: 'rgba(186,43,76,0.12)', fg: 'var(--danger)' },
    neutral: { bg: 'rgba(75,35,128,0.08)', fg: 'var(--ink-2)' },
  }
  const { bg, fg } = palette[tone]
  return (
    <span className="inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold" style={{ background: bg, color: fg }}>
      {children}
    </span>
  )
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`glass rounded-3xl p-5 sm:p-6 ${className}`}>{children}</section>
}

export function SectionTitle({ icon, title, hint }: { icon: ReactNode; title: string; hint?: string }) {
  return (
    <div className="mb-4 flex items-start gap-3">
      <div className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-xl" style={{ background: 'rgba(75,35,128,0.08)', color: 'var(--ink)' }}>
        {icon}
      </div>
      <div>
        <h2 className="display text-lg font-semibold leading-tight text-balance">{title}</h2>
        {hint && <p className="mt-0.5 max-w-prose text-xs text-pretty" style={{ color: 'var(--muted)' }}>{hint}</p>}
      </div>
    </div>
  )
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: string }) {
  return (
    <div className="inner rounded-2xl p-3.5">
      <div className="text-xs font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>{label}</div>
      <div className="display num mt-1 text-xl font-bold tabular-nums">{value}</div>
      {sub && <div className="mt-0.5 text-xs" style={{ color: 'var(--muted)' }}>{sub}</div>}
    </div>
  )
}

export function TxLink({ hash, label }: { hash?: string; label: string }) {
  if (!hash) return null
  return (
    <a
      href={buildTxExplorerUrl(CHAIN_ID, hash)}
      target="_blank"
      rel="noreferrer noopener"
      className="inline-flex items-center gap-1 text-xs font-semibold"
      style={{ color: 'var(--accent-hover)' }}
    >
      {label}
      <ExternalLink className="size-3" aria-hidden />
    </a>
  )
}

export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-xs font-semibold" style={{ color: 'var(--ink-2)' }}>{label}</span>
      {children}
      {hint && <span className="mt-1 block text-xs" style={{ color: 'var(--subtle)' }}>{hint}</span>}
    </label>
  )
}

export const inputClass = 'inner min-h-11 w-full rounded-2xl bg-white/70 px-3.5 text-sm outline-none placeholder:text-slate-400'
