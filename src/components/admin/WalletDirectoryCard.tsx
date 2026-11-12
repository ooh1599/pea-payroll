import { useRef, useState } from 'react'
import { Download, Trash2, Users } from 'lucide-react'
import { toast } from 'sonner'
import { useWalletDirectory } from '@/hooks/useWalletDirectory'
import { useLang } from '@/lib/i18n'
import { DIRECTORY_TEMPLATE, parseDirectoryTable } from '@/lib/sap'
import { downloadText, readTable } from '@/lib/sapFile'
import { Btn, Card, SectionTitle } from '@/components/ui'

export function WalletDirectoryCard() {
  const { t, lang } = useLang()
  const { count, updatedAt, save, clear } = useWalletDirectory()
  const inputRef = useRef<HTMLInputElement>(null)
  const [errors, setErrors] = useState<string[]>([])

  const onFile = async (file: File | undefined) => {
    if (!file) return
    if (inputRef.current) inputRef.current.value = ''
    try {
      const result = parseDirectoryTable(await readTable(file))
      setErrors(result.errors.slice(0, 8))
      if (result.count > 0 && result.errors.length === 0) {
        save(result.map)
        toast.success(t(`บันทึกกระเป๋าพนักงาน ${result.count} คน`, `Saved ${result.count} employee wallets.`))
      } else if (result.errors.length > 0) {
        toast.error(t('ไฟล์มีข้อผิดพลาด ยังไม่ได้บันทึก', 'The file has errors and was not saved.'))
      }
    } catch (error) {
      setErrors([error instanceof Error ? error.message : 'Could not read the file.'])
    }
  }

  return (
    <Card>
      <SectionTitle
        icon={<Users className="size-4" aria-hidden />}
        title={t('0. ทะเบียนกระเป๋าพนักงาน', '0. Employee wallet directory')}
        hint={t(
          'SAP ไม่มีช่องที่อยู่กระเป๋า HR อัปโหลดรายชื่อรหัสพนักงาน (PERNR) คู่กับกระเป๋าครั้งเดียว แล้วใช้กับทุกงวด ข้อมูลเก็บในเบราว์เซอร์นี้เท่านั้น',
          'SAP has no wallet field. Upload a list of employee IDs (PERNR) with wallets once and reuse it for every payrun. It is stored in this browser only.',
        )}
      />
      <input ref={inputRef} type="file" accept=".csv,.tsv,.txt,.xlsx" className="sr-only" onChange={(e) => void onFile(e.target.files?.[0])} />
      <div className="flex flex-wrap items-center gap-2.5">
        <Btn variant="ghost" size="sm" onClick={() => inputRef.current?.click()}>
          {count > 0 ? t('แทนที่รายชื่อ', 'Replace list') : t('อัปโหลดรายชื่อ', 'Upload list')}
        </Btn>
        <Btn variant="ghost" size="sm" onClick={() => downloadText('wallet-directory-template.csv', DIRECTORY_TEMPLATE)}>
          <Download className="size-3.5" aria-hidden />
          {t('เทมเพลต', 'Template')}
        </Btn>
        {count > 0 && (
          <>
            <span className="text-xs" style={{ color: 'var(--muted)' }}>
              <b className="tabular-nums">{count}</b> {t('คน', 'employees')} · {new Intl.DateTimeFormat(lang === 'th' ? 'th-TH' : 'en-GB', { dateStyle: 'medium' }).format(new Date(updatedAt))}
            </span>
            <Btn variant="danger" size="sm" onClick={clear} aria-label={t('ลบรายชื่อ', 'Clear list')}>
              <Trash2 className="size-3.5" aria-hidden />
            </Btn>
          </>
        )}
      </div>
      {errors.length > 0 && (
        <ul role="alert" className="mt-3 grid gap-1 text-xs" style={{ color: 'var(--danger)' }}>
          {errors.map((m) => <li key={m}>{m}</li>)}
        </ul>
      )}
      <p className="mt-3 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
        {t(
          'หากไฟล์เงินเดือนมีคอลัมน์ wallet_address อยู่แล้ว ไม่ต้องอัปโหลดรายชื่อนี้',
          'If your payroll file already has a wallet_address column you do not need this list.',
        )}
      </p>
    </Card>
  )
}
