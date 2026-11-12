import { useState } from 'react'
import { BRAND } from '@/brand'

/** Brand emblem from public/logo.png, with a neutral purple and gold badge until the file is added. */
export function Logo({ size = 44 }: { size?: number }) {
  const [failed, setFailed] = useState(false)
  if (!failed) {
    return (
      <img
        src={BRAND.logoSrc}
        alt={BRAND.nameEn}
        width={size}
        height={size}
        className="shrink-0 rounded-full object-contain"
        style={{ width: size, height: size }}
        onError={() => setFailed(true)}
      />
    )
  }
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" role="img" aria-label={BRAND.nameEn} className="shrink-0">
      <circle cx="32" cy="32" r="31" fill="#4b2380" />
      <circle cx="32" cy="32" r="26" fill="none" stroke="#e6c57a" strokeWidth="1.5" />
      <circle cx="32" cy="32" r="21" fill="#fff8e8" />
      <path d="M35 14 22 35h8l-3 15 15-23h-9z" fill="#b9892b" />
    </svg>
  )
}
