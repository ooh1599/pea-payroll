import { getAddress, isAddress, keccak256, toBytes, type Address } from 'viem'
import { parseUsdc } from '@/onchain-money'

export interface PayrollRow {
  line: number
  employeeId: string
  name: string
  wallet: string
  amountText: string
  currency: string
  errors: string[]
}

export interface PayrollEntry {
  wallet: Address
  /** Amount to pay, in USDC base units (6 decimals). */
  amountRaw: bigint
  /** Amount as exported from SAP, in the file currency (6 decimals). */
  sourceRaw: bigint
  employeeId: string
  name: string
  ref: `0x${string}`
  mergedLines: number
}

export interface ParsedPayroll {
  rows: PayrollRow[]
  entries: PayrollEntry[]
  /** Total in USDC base units. */
  total: bigint
  /** Total in the SAP file currency (6 decimals). */
  sourceTotal: bigint
  currency: string
  currencyFromFile: boolean
  needsRate: boolean
  skippedRows: number
  warnings: string[]
  fileErrors: string[]
  hasErrors: boolean
}

export interface ParseOptions {
  /** Employee ID (leading zeros stripped) -> wallet, used when the SAP export has no wallet column. */
  directory: Record<string, string>
  /** Currency assumed when the file has no currency column. */
  defaultCurrency: string
  /** Units of file currency per 1 USDC, 6 decimals. Required unless the currency is USDC. */
  rate: bigint | null
}

const MATCHERS = {
  employeeId: (h: string) =>
    /^(employee_id|employeeid|emp_id|empid|emp_no|staff_id|pernr|pers_no|pers_nr|personnel_(number|no|id)|employee_number|รหัสพนักงาน)$/.test(h),
  name: (h: string) => /^(name|ename|sname|full_name|employee_name|employee_or_applicant_name|ชื่อ|ชื่อพนักงาน)$/.test(h),
  wallet: (h: string) => /^(wallet|wallet_address|address|usdc_wallet|evm_address|กระเป๋า)$/.test(h),
  amount: (h: string) =>
    /^(amount|net_pay|netpay|net_amount|net_salary|net_payment|payment_amount|salary|amount_usdc|usdc|betrg|amt|bet01|เงินเดือนสุทธิ|จำนวนเงิน)$/.test(h),
  currency: (h: string) => /^(currency|crcy|waers|curr|cur|สกุลเงิน)$/.test(h),
} as const

type Key = keyof typeof MATCHERS

export const PAYROLL_TEMPLATE =
  'PERNR,ENAME,BETRG,WAERS\n00001001,Somchai Jaidee,45000.00,THB\n00001002,Suda Rakdee,52500.50,THB\n'
export const DIRECTORY_TEMPLATE = 'PERNR,wallet_address\n00001001,0xYOUR_EMPLOYEE_WALLET_ADDRESS\n00001002,0xYOUR_EMPLOYEE_WALLET_ADDRESS\n'

export const normHeader = (h: string) =>
  h.trim().toLowerCase().replace(/^\uFEFF/, '').replace(/[^\p{L}\p{N}]+/gu, '_').replace(/^_+|_+$/g, '')

/** SAP personnel numbers are zero padded ("00001001"); Excel drops the zeros. Compare without them. */
export const idKey = (id: string) => id.trim().replace(/^0+(?=\d)/, '')

function findHeader(table: string[][], required: Key[]): { index: number; cols: Record<Key, number> } | null {
  for (let i = 0; i < Math.min(table.length, 30); i++) {
    const headers = table[i].map(normHeader)
    const cols = {} as Record<Key, number>
    for (const key of Object.keys(MATCHERS) as Key[]) cols[key] = headers.findIndex((h) => h !== '' && MATCHERS[key](h))
    if (required.every((k) => cols[k] >= 0)) return { index: i, cols }
  }
  return null
}

/**
 * Normalises "1,234.50", "1.234,50", "1 234,50", "1234.5" and SAP trailing-minus "100-" into a plain decimal string.
 * A single separator followed by exactly three digits ("1,234" or "1.234") is ambiguous between a
 * thousands mark and a decimal mark, so it is rejected instead of guessed: a wrong guess is a 1000x payment error.
 */
export function normalizeAmount(input: string): string {
  let s = input.trim().replace(/\s+/g, '').replace(/^(usdc|\$)/i, '').replace(/usdc$/i, '')
  let negative = false
  if (s.endsWith('-')) {
    negative = true
    s = s.slice(0, -1)
  } else if (s.startsWith('-')) {
    negative = true
    s = s.slice(1)
  }
  const hasComma = s.includes(',')
  const hasDot = s.includes('.')
  if (hasComma && hasDot) {
    // Whichever separator comes last is the decimal mark.
    s = s.lastIndexOf(',') > s.lastIndexOf('.') ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,/g, '')
  } else if (hasComma || hasDot) {
    const sep = hasComma ? ',' : '.'
    const parts = s.split(sep)
    if (parts.length > 2) {
      if (!parts.slice(1).every((p) => p.length === 3)) throw new Error('AMBIGUOUS')
      s = parts.join('')
    } else if (/^\d{1,3}$/.test(parts[0]) && parts[1].length === 3) {
      throw new Error('AMBIGUOUS')
    } else if (hasComma) {
      s = s.replace(',', '.')
    }
  }
  return negative ? `-${s}` : s
}

/** Exchange rate text such as "35.50" -> 6-decimal bigint, or null when empty/invalid/not positive. */
export function parseRate(text: string): bigint | null {
  if (!text.trim()) return null
  try {
    const v = parseUsdc(normalizeAmount(text))
    return v > 0n ? v : null
  } catch {
    return null
  }
}

/** fiat (6dp) / rate (fiat per USDC, 6dp) -> USDC (6dp), rounded half up. */
export function convertToUsdc(sourceRaw: bigint, rate: bigint): bigint {
  return (sourceRaw * 1_000_000n + rate / 2n) / rate
}

export function sapRunIdHash(sapRunId: string): `0x${string}` {
  return keccak256(toBytes(sapRunId.trim()))
}

export function employeeRef(employeeId: string): `0x${string}` {
  return keccak256(toBytes(idKey(employeeId)))
}

const SUMMARY = /^(total|grand\s*total|sub\s*total|sum|รวม|ผลรวม)/i

export function parsePayrollTable(table: string[][], opts: ParseOptions): ParsedPayroll {
  const empty: ParsedPayroll = {
    rows: [],
    entries: [],
    total: 0n,
    sourceTotal: 0n,
    currency: opts.defaultCurrency,
    currencyFromFile: false,
    needsRate: false,
    skippedRows: 0,
    warnings: [],
    fileErrors: [],
    hasErrors: true,
  }
  const header = findHeader(table, ['employeeId', 'amount'])
  if (!header) {
    return { ...empty, fileErrors: ['Could not find a header row with an employee ID column (PERNR / Pers.No. / employee_id) and an amount column (BETRG / Amount / net_pay).'] }
  }
  const { cols } = header
  const cell = (cells: string[], col: number) => (col >= 0 ? (cells[col] ?? '').trim() : '')

  const rows: PayrollRow[] = []
  const parsed: { row: PayrollRow; wallet?: Address; sourceRaw?: bigint; currency: string }[] = []
  const warnings: string[] = []
  const reportedTotals: bigint[] = []
  let skippedRows = 0

  for (let i = header.index + 1; i < table.length; i++) {
    const cells = table[i]
    if (cells.every((c) => c.trim() === '')) continue
    const employeeId = cell(cells, cols.employeeId)
    const walletCell = cell(cells, cols.wallet)
    const first = cells.find((c) => c.trim() !== '') ?? ''
    if ((!employeeId && !walletCell) || SUMMARY.test(employeeId || first.trim())) {
      // Total / subtotal rows that SAP lists append. They are never paid.
      skippedRows++
      try {
        reportedTotals.push(parseUsdc(normalizeAmount(cell(cells, cols.amount))))
      } catch {
        /* not a numeric total row */
      }
      continue
    }
    const currency = (cell(cells, cols.currency) || opts.defaultCurrency).toUpperCase()
    const row: PayrollRow = {
      line: i + 1,
      employeeId,
      name: cell(cells, cols.name),
      wallet: walletCell || opts.directory[idKey(employeeId)] || '',
      amountText: cell(cells, cols.amount),
      currency,
      errors: [],
    }
    let wallet: Address | undefined
    let sourceRaw: bigint | undefined
    if (!employeeId) row.errors.push('Missing employee ID')
    if (!row.wallet) row.errors.push('No wallet registered for this employee')
    else if (!isAddress(row.wallet)) row.errors.push('Invalid wallet address or checksum')
    else if (/^0x0{40}$/i.test(row.wallet)) row.errors.push('Wallet is the zero address')
    else wallet = getAddress(row.wallet.toLowerCase())
    try {
      sourceRaw = parseUsdc(normalizeAmount(row.amountText))
      if (sourceRaw <= 0n) {
        row.errors.push(sourceRaw < 0n ? 'Negative amount' : 'Amount must be greater than zero')
        sourceRaw = undefined
      }
    } catch (error) {
      row.errors.push(
        error instanceof Error && error.message === 'AMBIGUOUS'
          ? 'Ambiguous amount: export with a plain number such as 1234.00 and no thousands separator'
          : 'Invalid amount (max 6 decimals)',
      )
    }
    rows.push(row)
    parsed.push({ row, wallet, sourceRaw, currency })
  }

  const currencies = new Set(parsed.map((p) => p.currency))
  const fileErrors: string[] = []
  if (rows.length === 0) fileErrors.push('The file has no employee rows.')
  if (currencies.size > 1) fileErrors.push(`The file mixes currencies (${[...currencies].join(', ')}). Export one currency per payrun.`)
  const currency = currencies.size === 1 ? [...currencies][0] : opts.defaultCurrency
  const needsRate = currency !== 'USDC'
  const rate = needsRate ? opts.rate : 1_000_000n
  if (needsRate && rate === null) fileErrors.push(`Enter the exchange rate (${currency} per 1 USDC) to convert the amounts.`)

  // One employee ID <-> one wallet.
  const walletsByEmployee = new Map<string, Set<string>>()
  const employeesByWallet = new Map<string, Set<string>>()
  for (const { row, wallet } of parsed) {
    if (!wallet || !row.employeeId) continue
    const w = wallet.toLowerCase()
    const k = idKey(row.employeeId)
    walletsByEmployee.set(k, (walletsByEmployee.get(k) ?? new Set()).add(w))
    employeesByWallet.set(w, (employeesByWallet.get(w) ?? new Set()).add(k))
  }
  for (const { row, wallet } of parsed) {
    if (!wallet || !row.employeeId) continue
    if ((walletsByEmployee.get(idKey(row.employeeId))?.size ?? 0) > 1) row.errors.push('Employee ID has more than one wallet')
    if ((employeesByWallet.get(wallet.toLowerCase())?.size ?? 0) > 1) row.errors.push('Wallet is shared by several employees')
  }

  // Merge repeated lines of the same employee (several SAP wage types) into one payment, then convert once.
  const merged = new Map<string, PayrollEntry>()
  for (const { row, wallet, sourceRaw } of parsed) {
    if (row.errors.length > 0 || !wallet || sourceRaw === undefined) continue
    const key = wallet.toLowerCase()
    const existing = merged.get(key)
    if (existing) {
      existing.sourceRaw += sourceRaw
      existing.mergedLines += 1
    } else {
      merged.set(key, { wallet, amountRaw: 0n, sourceRaw, employeeId: row.employeeId, name: row.name, ref: employeeRef(row.employeeId), mergedLines: 1 })
    }
  }
  const entries = [...merged.values()]
  for (const e of entries) {
    e.amountRaw = rate === null ? 0n : convertToUsdc(e.sourceRaw, rate)
    if (rate !== null && e.amountRaw === 0n) fileErrors.push(`Employee ${e.employeeId} converts to 0 USDC.`)
  }
  const sourceTotal = entries.reduce((sum, e) => sum + e.sourceRaw, 0n)
  const total = entries.reduce((sum, e) => sum + e.amountRaw, 0n)

  if (reportedTotals.length > 0 && !reportedTotals.includes(sourceTotal) && rows.every((r) => r.errors.length === 0)) {
    warnings.push('The total row in the SAP file does not match the sum of the employee rows (it may be a subtotal).')
  }

  const hasErrors = fileErrors.length > 0 || rows.some((r) => r.errors.length > 0) || entries.length === 0
  return {
    rows,
    entries,
    total,
    sourceTotal,
    currency,
    currencyFromFile: cols.currency >= 0,
    needsRate,
    skippedRows,
    warnings,
    fileErrors,
    hasErrors,
  }
}

export interface DirectoryResult {
  map: Record<string, string>
  count: number
  errors: string[]
}

/** Employee wallet directory: employee ID -> wallet. SAP has no wallet field, so HR maintains this list. */
export function parseDirectoryTable(table: string[][]): DirectoryResult {
  const header = findHeader(table, ['employeeId', 'wallet'])
  if (!header) return { map: {}, count: 0, errors: ['Could not find columns for the employee ID (PERNR / employee_id) and wallet_address.'] }
  const map: Record<string, string> = {}
  const owners = new Map<string, string>()
  const errors: string[] = []
  for (let i = header.index + 1; i < table.length; i++) {
    const cells = table[i]
    if (cells.every((c) => c.trim() === '')) continue
    const id = (cells[header.cols.employeeId] ?? '').trim()
    const w = (cells[header.cols.wallet] ?? '').trim()
    if (!id || !w) {
      errors.push(`Line ${i + 1}: missing employee ID or wallet.`)
      continue
    }
    if (!isAddress(w) || /^0x0{40}$/i.test(w)) {
      errors.push(`Line ${i + 1}: invalid wallet address or checksum.`)
      continue
    }
    const key = idKey(id)
    const addr = getAddress(w.toLowerCase())
    if (map[key] && map[key] !== addr) {
      errors.push(`Line ${i + 1}: employee ${id} appears with two different wallets.`)
      continue
    }
    const other = owners.get(addr.toLowerCase())
    if (other && other !== key) {
      errors.push(`Line ${i + 1}: wallet is already assigned to employee ${other}.`)
      continue
    }
    map[key] = addr
    owners.set(addr.toLowerCase(), key)
  }
  return { map, count: Object.keys(map).length, errors }
}
