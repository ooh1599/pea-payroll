import { useEffect, useState } from 'react'
import { animate, useMotionValue } from 'framer-motion'
import { fmtUsdc } from '@/lib/payroll'

const formatter = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const toNumber = (raw: bigint) => Number(raw) / 1_000_000

/** Counts up to the new amount; always settles on the exact value read from the chain. */
export function AnimatedUsdc({ raw }: { raw: bigint }) {
  const value = useMotionValue(toNumber(raw))
  const [text, setText] = useState(() => fmtUsdc(raw))

  useEffect(() => {
    const controls = animate(value, toNumber(raw), {
      duration: 0.7,
      ease: 'easeOut',
      onUpdate: (v) => setText(formatter.format(v)),
      onComplete: () => setText(fmtUsdc(raw)),
    })
    return () => controls.stop()
  }, [raw, value])

  return <span className="tabular-nums">{text}</span>
}
