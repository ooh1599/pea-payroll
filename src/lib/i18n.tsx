import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export type Lang = 'th' | 'en'

interface LangCtx {
  lang: Lang
  setLang: (lang: Lang) => void
  /** Pick the string for the active language: t('ไทย', 'English'). */
  t: (th: string, en: string) => string
}

const Ctx = createContext<LangCtx | null>(null)
const STORAGE_KEY = 'payroll-lang'

export function LangProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(() => {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored === 'th' || stored === 'en') return stored
    return navigator.language.toLowerCase().startsWith('th') ? 'th' : 'en'
  })
  useEffect(() => {
    document.documentElement.lang = lang
  }, [lang])
  const setLang = useCallback((next: Lang) => {
    localStorage.setItem(STORAGE_KEY, next)
    setLangState(next)
  }, [])
  const value = useMemo<LangCtx>(() => ({ lang, setLang, t: (th, en) => (lang === 'th' ? th : en) }), [lang, setLang])
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useLang(): LangCtx {
  const ctx = useContext(Ctx)
  if (!ctx) throw new Error('useLang must be used inside LangProvider')
  return ctx
}
