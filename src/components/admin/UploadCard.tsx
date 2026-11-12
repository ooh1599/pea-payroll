import { useMemo, useRef, useState, type DragEvent } from 'react'
import { parseEventLogs } from 'viem'
import { usePublicClient } from 'wagmi'
import { toast } from 'sonner'
import { CheckCircle2, Download, FileSpreadsheet, UploadCloud } from 'lucide-react'
import { useTx } from '@/hooks/useTx'
import { useWalletDirectory } from '@/hooks/useWalletDirectory'
import { useLang } from '@/lib/i18n'
import { CHAIN_ID, MAX_ENTRIES_PER_TX, MAX_LABEL_BYTES, RUN_STATUS, VAULT_ADDRESS, fmtUsdc, vaultAbi, type RunData } from '@/lib/payroll'
import { PAYROLL_TEMPLATE, normalizeAmount, parsePayrollTable, parseRate, sapRunIdHash } from '@/lib/sap'
import { downloadText, readTable } from '@/lib/sapFile'
import { parseUsdc } from '@/onchain-money'
import { Btn, Card, Chip, Field, SectionTitle, inputClass } from '@/components/ui'
import { PayrollPreview } from '@/components/admin/PayrollPreview'

type Phase = 'idle' | 'create' | 'upload' | 'done' | 'error'

interface Progress {
  phase: Phase
  chunk: number
  chunks: number
  runId?: number
}

const CURRENCIES = ['USDC', 'USD', 'THB', 'EUR', 'GBP', 'SGD', 'JPY', 'AUD']

export function UploadCard({ runs }: { runs: RunData[] }) {
  const { t } = useLang()
  const publicClient = usePublicClient({ chainId: CHAIN_ID })
  const { run, busy, stage } = useTx()
  const { directory } = useWalletDirectory()
  const inputRef = useRef<HTMLInputElement>(null)

  const [fileName, setFileName] = useState('')
  const [table, setTable] = useState<string[][] | null>(null)
  const [readError, setReadError] = useState('')
  const [sapId, setSapId] = useState('')
  const [desc, setDesc] = useState('')
  const [days, setDays] = useState('30')
  const [controlTotal, setControlTotal] = useState('')
  const [currencyChoice, setCurrencyChoice] = useState('THB')
  const [rateText, setRateText] = useState('')
  const [dragging, setDragging] = useState(false)
  const [progress, setProgress] = useState<Progress>({ phase: 'idle', chunk: 0, chunks: 0 })

  const rate = useMemo(() => parseRate(rateText), [rateText])
  const parsed = useMemo(
    () => (table ? parsePayrollTable(table, { directory, defaultCurrency: currencyChoice.trim().toUpperCase() || 'USDC', rate }) : null),
    [table, directory, currencyChoice, rate],
  )

  const existingRun = useMemo(() => {
    if (!sapId.trim()) return undefined
    const hash = sapRunIdHash(sapId)
    return runs.find((r) => r.sapRunId === hash)
  }, [runs, sapId])

  const blockedByExisting = existingRun !== undefined && existingRun.status !== RUN_STATUS.Draft
  const conversionNote = parsed?.needsRate && rate ? ` [${parsed.currency}@${rateText.trim()}]` : ''
  const label = (desc.trim() ? `${sapId.trim()} · ${desc.trim()}` : sapId.trim()) + conversionNote
  const labelTooLong = new TextEncoder().encode(label).length > MAX_LABEL_BYTES

  // Optional reconciliation against the total printed on the SAP payroll report (in the SAP currency).
  const controlRaw = useMemo(() => {
    if (!controlTotal.trim()) return null
    try {
      return parseUsdc(normalizeAmount(controlTotal))
    } catch {
      return undefined
    }
  }, [controlTotal])
  const controlMismatch = Boolean(parsed && controlRaw !== null && (controlRaw === undefined || controlRaw !== parsed.sourceTotal))

  const canSubmit = Boolean(parsed && !parsed.hasErrors && sapId.trim() && !blockedByExisting && !labelTooLong && !controlMismatch)

  const onFile = async (file: File | undefined) => {
    if (!file) return
    setFileName(file.name)
    if (inputRef.current) inputRef.current.value = ''
    setProgress({ phase: 'idle', chunk: 0, chunks: 0 })
    setReadError('')
    try {
      setTable(await readTable(file))
    } catch (error) {
      setTable(null)
      setReadError(error instanceof Error ? error.message : 'Could not read this file.')
    }
  }

  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault()
    setDragging(false)
    void onFile(event.dataTransfer.files[0])
  }

  const submit = async () => {
    if (!parsed || !publicClient || !VAULT_ADDRESS || !canSubmit) return
    const vault = VAULT_ADDRESS
    try {
      let runId = existingRun?.id
      if (runId === undefined) {
        setProgress({ phase: 'create', chunk: 0, chunks: 0 })
        const days_ = Math.max(0, Math.floor(Number(days) || 0))
        const deadline = days_ > 0 ? BigInt(Math.floor(Date.now() / 1000) + days_ * 86400) : 0n
        const created = await run({
          address: vault,
          abi: vaultAbi,
          functionName: 'createPayrun',
          args: [sapRunIdHash(sapId), label, deadline, BigInt(parsed.entries.length), parsed.total],
        })
        if (!created) return setProgress({ phase: 'error', chunk: 0, chunks: 0 })
        const log = parseEventLogs({ abi: vaultAbi, eventName: 'PayrunCreated', logs: created.receipt.logs })[0]
        if (!log) throw new Error('PayrunCreated event not found')
        runId = Number(log.args.runId)
      }

      // Resume support: skip employees already stored in this draft run, and refuse a file that disagrees with them.
      let pending = parsed.entries
      if (existingRun) {
        const checks = await publicClient.multicall({
          allowFailure: false,
          contracts: parsed.entries.map((e) => ({ address: vault, abi: vaultAbi, functionName: 'getEntry' as const, args: [BigInt(runId), e.wallet] as const })),
        })
        const conflict = parsed.entries.find((e, i) => checks[i].amount !== 0n && checks[i].amount !== e.amountRaw)
        if (conflict) {
          toast.error(t(`พนักงาน ${conflict.employeeId} มียอดในร่างไม่ตรงกับไฟล์นี้ ใช้รหัสรอบใหม่`, `Employee ${conflict.employeeId} already has a different amount in this draft. Use a new run ID.`))
          return setProgress({ phase: 'error', chunk: 0, chunks: 0, runId })
        }
        pending = parsed.entries.filter((_, i) => checks[i].amount === 0n)
      }

      const chunks: (typeof pending)[] = []
      for (let i = 0; i < pending.length; i += MAX_ENTRIES_PER_TX) chunks.push(pending.slice(i, i + MAX_ENTRIES_PER_TX))
      for (let i = 0; i < chunks.length; i++) {
        setProgress({ phase: 'upload', chunk: i + 1, chunks: chunks.length, runId })
        const c = chunks[i]
        const ok = await run({
          address: vault,
          abi: vaultAbi,
          functionName: 'addEntries',
          args: [BigInt(runId), c.map((e) => e.wallet), c.map((e) => e.amountRaw), c.map((e) => e.ref)],
        })
        if (!ok) return setProgress({ phase: 'error', chunk: i + 1, chunks: chunks.length, runId })
      }
      setProgress({ phase: 'done', chunk: chunks.length, chunks: chunks.length, runId })
      toast.success(t('อัปโหลดแล้ว สถานะร่าง เติมเงินและเปิดงวดด้านล่าง', 'Uploaded as a draft. Fund and open the payrun below.'))
    } catch {
      toast.error(t('อัปโหลดไม่สำเร็จ ลองอีกครั้ง ระบบจะต่อจากรายการที่ค้างไว้', 'Upload failed. Retry and it will continue where it stopped.'))
      setProgress((p) => ({ ...p, phase: 'error' }))
    }
  }

  return (
    <Card>
      <SectionTitle
        icon={<UploadCloud className="size-4" aria-hidden />}
        title={t('1. นำเข้าข้อมูลเงินเดือนจาก SAP ERP', '1. Import payroll from SAP ERP')}
        hint={t(
          'ใน SAP รันรายงานผลเงินเดือน แล้วเลือก Export > Spreadsheet (XLSX) หรือ Local file ต้องมีคอลัมน์รหัสพนักงาน (PERNR) และยอดสุทธิ (BETRG) ส่วนสกุลเงิน (WAERS) และชื่อมีหรือไม่มีก็ได้',
          'In SAP run the payroll results report, then choose Export > Spreadsheet (XLSX) or Local file. It needs the personnel number (PERNR) and net amount (BETRG); currency (WAERS) and name are optional.',
        )}
      />

      <div className="grid gap-3 sm:grid-cols-2">
        <Field label={t('รหัสรอบเงินเดือน SAP', 'SAP payroll run ID')} hint={t('ใช้ซ้ำไม่ได้ เช่น PAY-2026-11', 'Cannot be reused, e.g. PAY-2026-11')}>
          <input className={inputClass} value={sapId} onChange={(e) => setSapId(e.target.value)} placeholder="PAY-2026-11" autoComplete="off" />
        </Field>
        <Field label={t('คำอธิบาย (ไม่บังคับ)', 'Description (optional)')}>
          <input className={inputClass} value={desc} onChange={(e) => setDesc(e.target.value)} placeholder={t('เงินเดือนพฤศจิกายน', 'November salary')} />
        </Field>
        <Field label={t('กำหนดเคลมภายใน (วัน, 0 = ไม่จำกัด)', 'Claim window (days, 0 = no limit)')}>
          <input className={inputClass} inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value.replace(/\D/g, ''))} />
        </Field>
        <Field
          label={t(`ยอดรวมตามรายงาน SAP${parsed ? ` (${parsed.currency})` : ''} (ไม่บังคับ)`, `Total per SAP report${parsed ? ` (${parsed.currency})` : ''} (optional)`)}
          hint={t('ใช้ตรวจว่ายอดรวมในไฟล์ตรงกับรายงาน', 'Reconciles the file total against your SAP report')}
        >
          <input className={inputClass} inputMode="decimal" value={controlTotal} onChange={(e) => setControlTotal(e.target.value)} placeholder="0.00" />
        </Field>
      </div>

      <input ref={inputRef} type="file" accept=".xlsx,.xls,.csv,.tsv,.txt,.htm,.html,text/csv" className="sr-only" onChange={(e) => void onFile(e.target.files?.[0])} />
      <div
        role="button"
        tabIndex={0}
        onClick={() => inputRef.current?.click()}
        onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && inputRef.current?.click()}
        onDragOver={(e) => {
          e.preventDefault()
          setDragging(true)
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        className="mt-4 flex cursor-pointer flex-col items-center gap-2 rounded-2xl border-2 border-dashed px-4 py-7 text-center transition-colors"
        style={{ borderColor: dragging ? 'var(--accent-hover)' : 'var(--border-strong)', background: dragging ? 'rgba(155,120,214,0.14)' : 'rgba(255,255,255,0.5)' }}
      >
        <FileSpreadsheet className="size-7" style={{ color: 'var(--accent-hover)' }} aria-hidden />
        <div className="text-sm font-semibold">{fileName || t('ลากไฟล์ XLSX / CSV จาก SAP มาวาง หรือคลิกเพื่อเลือก', 'Drop the SAP XLSX / CSV export here or click to browse')}</div>
        <div className="text-xs" style={{ color: 'var(--muted)' }}>
          {t('รองรับ .xlsx, .xls (HTML), .csv, .txt และ Windows-874 / UTF-16', 'Supports .xlsx, .xls (HTML), .csv, .txt and Windows-874 / UTF-16 encodings')}
        </div>
        <Btn
          variant="ghost"
          size="sm"
          onClick={(e) => {
            e.stopPropagation()
            downloadText('sap-payroll-template.csv', PAYROLL_TEMPLATE)
          }}
        >
          <Download className="size-3.5" aria-hidden />
          {t('ดาวน์โหลดตัวอย่างไฟล์', 'Download sample file')}
        </Btn>
      </div>
      {readError && <p role="alert" className="mt-2 text-sm" style={{ color: 'var(--danger)' }}>{readError}</p>}

      {parsed && (!parsed.currencyFromFile || parsed.needsRate) && (
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          {!parsed.currencyFromFile && (
            <Field label={t('สกุลเงินในไฟล์', 'Currency in the file')} hint={t('ไฟล์ไม่มีคอลัมน์สกุลเงิน (WAERS)', 'The file has no currency column (WAERS)')}>
              <input className={inputClass} list="currency-options" value={currencyChoice} onChange={(e) => setCurrencyChoice(e.target.value.toUpperCase().slice(0, 5))} />
              <datalist id="currency-options">{CURRENCIES.map((c) => <option key={c} value={c} />)}</datalist>
            </Field>
          )}
          {parsed.needsRate && (
            <Field
              label={t(`อัตราแลกเปลี่ยน (${parsed.currency} ต่อ 1 USDC)`, `Exchange rate (${parsed.currency} per 1 USDC)`)}
              hint={t('กรอกอัตราที่บริษัทใช้จริง ระบบไม่ดึงอัตราให้ และบันทึกอัตรานี้ไว้ในชื่องวด', 'Enter the rate your treasury uses. The app does not fetch rates; it is recorded in the payrun name.')}
            >
              <input className={inputClass} inputMode="decimal" value={rateText} onChange={(e) => setRateText(e.target.value)} placeholder="35.50" />
            </Field>
          )}
        </div>
      )}

      {parsed && <PayrollPreview parsed={parsed} />}

      {existingRun && (
        <p className="mt-3 text-xs" style={{ color: blockedByExisting ? 'var(--danger)' : 'var(--warn)' }}>
          {blockedByExisting
            ? t('รหัสนี้ถูกใช้แล้วและไม่ใช่สถานะร่าง ใช้รหัสใหม่ เช่น เติม -v2', 'This ID was already used and is not a draft. Use a new ID, e.g. add -v2.')
            : t('พบงวดร่างที่ใช้รหัสนี้ ระบบจะอัปโหลดต่อเฉพาะพนักงานที่ยังไม่ถูกบันทึก', 'A draft with this ID exists. Only employees not yet stored will be uploaded.')}
        </p>
      )}
      {controlMismatch && (
        <p role="alert" className="mt-2 text-xs" style={{ color: 'var(--danger)' }}>
          {t('ยอดรวมในไฟล์ไม่ตรงกับยอดตามรายงาน SAP', 'The file total does not match the total from your SAP report.')}
          {parsed && <> ({fmtUsdc(parsed.sourceTotal)} {parsed.currency})</>}
        </p>
      )}
      {labelTooLong && <p role="alert" className="mt-2 text-xs" style={{ color: 'var(--danger)' }}>{t('รหัสและคำอธิบายยาวเกินไป', 'The ID and description are too long.')}</p>}

      <div className="mt-5 flex flex-wrap items-center gap-3">
        <Btn onClick={() => void submit()} loading={busy} disabled={!canSubmit}>
          {stage === 'wallet' ? t('ยืนยันในกระเป๋า…', 'Confirm in wallet…') : stage === 'confirming' ? t('กำลังยืนยันบนเชน…', 'Confirming…') : t('อัปโหลดขึ้นเชน (ร่าง)', 'Upload onchain (draft)')}
        </Btn>
        {parsed && parsed.rows.some((r) => r.errors.length > 0) && (
          <span className="text-xs" style={{ color: 'var(--danger)' }}>{t('แก้ไขแถวที่มีปัญหาแล้วเลือกไฟล์ใหม่', 'Fix the flagged rows and choose the file again.')}</span>
        )}
        {progress.phase === 'create' && <Chip tone="neutral">{t('กำลังสร้างงวด…', 'Creating payrun…')}</Chip>}
        {progress.phase === 'upload' && <Chip tone="neutral">{t(`อัปโหลดชุดที่ ${progress.chunk}/${progress.chunks}`, `Uploading batch ${progress.chunk}/${progress.chunks}`)}</Chip>}
        {progress.phase === 'done' && (
          <Chip tone="success"><CheckCircle2 className="mr-1 size-3" aria-hidden />{t(`งวด #${progress.runId} เป็นร่างแล้ว`, `Payrun #${progress.runId} saved as draft`)}</Chip>
        )}
        {progress.phase === 'error' && <Chip tone="danger">{t('หยุดกลางทาง กดอัปโหลดอีกครั้งเพื่อทำต่อ', 'Stopped. Press upload again to resume.')}</Chip>}
      </div>
      <p className="mt-3 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
        {t(
          'หมายเหตุ: ยอดเงินเดือนและที่อยู่กระเป๋าจะมองเห็นได้สาธารณะบนบล็อกเชน รหัสพนักงาน SAP ถูกเก็บเป็นค่าแฮชเท่านั้น ข้อมูลในไฟล์ถูกประมวลผลในเบราว์เซอร์ ไม่ถูกส่งไปที่เซิร์ฟเวอร์',
          'Note: salary amounts and wallet addresses are publicly visible onchain. SAP employee IDs are published only as hashes. The file is processed in your browser and never sent to a server.',
        )}
      </p>
    </Card>
  )
}
