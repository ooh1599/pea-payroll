import { readSheet } from 'read-excel-file/browser'

export class UnsupportedFileError extends Error {}

function decodeText(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return new TextDecoder('utf-16le').decode(bytes)
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return new TextDecoder('utf-16be').decode(bytes)
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch {
    // SAP GUI on Thai Windows exports local files as Windows-874 (TIS-620).
    return new TextDecoder('windows-874').decode(bytes)
  }
}

const DELIMITERS = [',', ';', '\t', '|']

/** Minimal RFC 4180 style parser (quotes, escaped quotes, CRLF). */
function parseDelimited(text: string, delimiter: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let inQuotes = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"'
          i++
        } else inQuotes = false
      } else field += ch
    } else if (ch === '"') inQuotes = true
    else if (ch === delimiter) {
      row.push(field)
      field = ''
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++
      row.push(field)
      field = ''
      if (row.some((c) => c.trim() !== '')) rows.push(row)
      row = []
    } else field += ch
  }
  row.push(field)
  if (row.some((c) => c.trim() !== '')) rows.push(row)
  return rows
}

function textToTable(raw: string): string[][] {
  const text = raw.replace(/^\uFEFF/, '')
  // SAP list output draws borders with lines of dashes and plus signs.
  const lines = text.split(/\r?\n/).filter((l) => !/^[\s\-+|=_]*$/.test(l))
  const sample = lines.slice(0, 15)
  let best = ','
  let bestCount = -1
  for (const d of DELIMITERS) {
    const count = sample.reduce((n, l) => n + l.split(d).length - 1, 0)
    if (count > bestCount) {
      best = d
      bestCount = count
    }
  }
  return parseDelimited(lines.join('\n'), best)
}

/** SAP's classic "Spreadsheet" export is an HTML table saved as .xls. */
function htmlToTable(html: string): string[][] {
  const doc = new DOMParser().parseFromString(html, 'text/html')
  return [...doc.querySelectorAll('tr')].map((tr) => [...tr.querySelectorAll('th,td')].map((c) => (c.textContent ?? '').replace(/\s+/g, ' ').trim()))
}

function cellToString(cell: unknown): string {
  if (cell === null || cell === undefined) return ''
  if (cell instanceof Date) return cell.toISOString().slice(0, 10)
  if (typeof cell === 'number') return Number.isInteger(cell) ? String(cell) : cell.toFixed(6).replace(/0+$/, '').replace(/\.$/, '')
  if (typeof cell === 'boolean') return String(cell)
  return typeof cell === 'string' ? cell.trim() : ''
}

/** Reads an SAP export (.xlsx, .xls HTML, .csv, .txt, .tsv) into a table of strings. */
export async function readTable(file: File): Promise<string[][]> {
  const buffer = await file.arrayBuffer()
  const head = new Uint8Array(buffer.slice(0, 4))
  const isZip = head[0] === 0x50 && head[1] === 0x4b // "PK": .xlsx container
  const isOle = head[0] === 0xd0 && head[1] === 0xcf // legacy binary .xls
  if (isOle) throw new UnsupportedFileError('Binary .xls is not supported. In Excel choose Save As > .xlsx or CSV.')
  if (isZip) {
    const data = await readSheet(new File([buffer], file.name))
    return data.map((row) => row.map(cellToString))
  }
  const text = decodeText(buffer)
  if (/^\s*<(html|table|\?xml|!doctype)/i.test(text) && /<table/i.test(text)) return htmlToTable(text)
  return textToTable(text)
}

export function downloadText(filename: string, content: string): void {
  const url = URL.createObjectURL(new Blob([content], { type: 'text/csv;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}
