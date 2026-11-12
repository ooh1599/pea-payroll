import { useCallback, useState } from 'react'

const KEY = 'payroll-wallet-directory-v1'

interface Stored {
  map: Record<string, string>
  updatedAt: number
}

function load(): Stored {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return { map: {}, updatedAt: 0 }
    const parsed = JSON.parse(raw) as Stored
    return parsed && typeof parsed.map === 'object' ? parsed : { map: {}, updatedAt: 0 }
  } catch {
    return { map: {}, updatedAt: 0 }
  }
}

/** Employee ID -> wallet list kept in this browser only (SAP has no wallet field). */
export function useWalletDirectory() {
  const [stored, setStored] = useState<Stored>(load)

  const save = useCallback((map: Record<string, string>) => {
    const next = { map, updatedAt: Date.now() }
    localStorage.setItem(KEY, JSON.stringify(next))
    setStored(next)
  }, [])

  const clear = useCallback(() => {
    localStorage.removeItem(KEY)
    setStored({ map: {}, updatedAt: 0 })
  }, [])

  return { directory: stored.map, count: Object.keys(stored.map).length, updatedAt: stored.updatedAt, save, clear }
}
