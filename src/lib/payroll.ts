import { parseAbi, type Address } from 'viem'
import { arcTestnet } from 'viem/chains'
import { getUsdc, USDC_DECIMALS } from '@/onchain-facts'
import { formatUnitsFixed } from '@/onchain-money'

export const CHAIN_ID = arcTestnet.id

const rawVault = import.meta.env.VITE_PAYROLL_VAULT_ADDRESS as string | undefined
export const VAULT_ADDRESS: Address | undefined = rawVault && /^0x[0-9a-fA-F]{40}$/.test(rawVault) ? (rawVault as Address) : undefined

const usdcFact = getUsdc(CHAIN_ID)
if (!usdcFact) throw new Error(`USDC is not registered for chain ${CHAIN_ID}`)
export const USDC_ADDRESS = usdcFact.address as Address

export const MAX_ENTRIES_PER_TX = 100

export const vaultAbi = parseAbi([
  'function owner() view returns (address)',
  'function paused() view returns (bool)',
  'function claimsPaused() view returns (bool)',
  'function totalOwed() view returns (uint256)',
  'function runCount() view returns (uint256)',
  'function sapRunIdUsed(bytes32) view returns (bool)',
  'function getRun(uint256 runId) view returns ((bytes32 sapRunId, string label, uint64 claimDeadline, uint128 totalAllocated, uint128 totalClaimed, uint128 totalRevoked, uint256 entryCount, uint8 status, bool expiredReleased, uint256 expectedEntryCount, uint128 expectedTotal, uint256 pausedBaseline))',
  'function effectiveDeadline(uint256 runId) view returns (uint256)',
  'function getEntry(uint256 runId, address employee) view returns ((uint128 amount, bool claimed, bool revoked))',
  'function claimable(uint256 runId, address employee) view returns (uint256)',
  'function createPayrun(bytes32 sapRunId, string label, uint64 claimDeadline, uint256 expectedEntryCount, uint256 expectedTotal) returns (uint256)',
  'function addEntries(uint256 runId, address[] employees, uint256[] amounts, bytes32[] employeeRefs)',
  'function openPayrun(uint256 runId)',
  'function cancelPayrun(uint256 runId)',
  'function claim(uint256 runId)',
  'function claimMany(uint256[] runIds)',
  'function revokeEntry(uint256 runId, address employee)',
  'function reclaimExpired(uint256 runId)',
  'function withdrawSurplus(address to, uint256 amount)',
  'function fund(uint256 amount)',
  'function pause()',
  'function unpause()',
  'event PayrunCreated(uint256 indexed runId, bytes32 indexed sapRunId, string label, uint64 claimDeadline)',
  'event Claimed(uint256 indexed runId, address indexed employee, uint256 amount)',
])

export const RUN_STATUS = { Draft: 0, Open: 1, Cancelled: 2 } as const

export interface RunData {
  id: number
  sapRunId: `0x${string}`
  label: string
  claimDeadline: number
  totalAllocated: bigint
  totalClaimed: bigint
  totalRevoked: bigint
  entryCount: number
  status: number
  expiredReleased: boolean
  expectedEntryCount: number
  expectedTotal: bigint
}

export interface RawRun {
  sapRunId: `0x${string}`
  label: string
  claimDeadline: bigint
  totalAllocated: bigint
  totalClaimed: bigint
  totalRevoked: bigint
  entryCount: bigint
  status: number
  expiredReleased: boolean
  expectedEntryCount: bigint
  expectedTotal: bigint
}

export function toRunData(id: number, r: RawRun, effectiveDeadline: bigint): RunData {
  return {
    id,
    sapRunId: r.sapRunId,
    label: r.label,
    claimDeadline: r.claimDeadline === 0n ? 0 : Number(effectiveDeadline),
    totalAllocated: r.totalAllocated,
    totalClaimed: r.totalClaimed,
    totalRevoked: r.totalRevoked,
    entryCount: Number(r.entryCount),
    status: r.status,
    expiredReleased: r.expiredReleased,
    expectedEntryCount: Number(r.expectedEntryCount),
    expectedTotal: r.expectedTotal,
  }
}

/** Claim deadlines are frozen while the vault is paused, so nothing expires during a pause. */
export function isExpired(run: RunData, nowSec: number, paused = false): boolean {
  return !paused && run.claimDeadline !== 0 && nowSec > run.claimDeadline
}

/** A draft can only be opened once the uploaded rows match the control totals it was created with. */
export function isUploadComplete(run: RunData): boolean {
  return run.entryCount === run.expectedEntryCount && run.totalAllocated === run.expectedTotal
}

export const MAX_LABEL_BYTES = 128

export function unclaimedOf(run: RunData): bigint {
  return run.totalAllocated - run.totalClaimed - run.totalRevoked
}

/** USDC amount as "1,234.56" for display. */
export function fmtUsdc(raw: bigint): string {
  const fixed = formatUnitsFixed(raw, USDC_DECIMALS, 2)
  const [whole, frac] = fixed.split('.')
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')}.${frac}`
}

export function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export function parseErr(error: unknown): string {
  const e = error as { code?: number; shortMessage?: string; message?: string } | undefined
  const msg = (e?.shortMessage ?? e?.message ?? '').toLowerCase()
  if (e?.code === 4001 || msg.includes('user rejected') || msg.includes('user denied')) return ''
  if (msg.includes('insufficientfunding')) return 'Vault is not fully funded for this payrun. Fund it first.'
  if (msg.includes('controltotalmismatch')) return 'Uploaded rows do not match the control totals. Finish the upload before opening.'
  if (msg.includes('exceedscontroltotals')) return 'This file has more employees or a larger total than the payrun was created with.'
  if (msg.includes('labeltoolong')) return 'The description is too long.'
  if (msg.includes('invalidrunstatus')) return 'This payrun is no longer in the right state for that action.'
  if (msg.includes('pausecooldownactive')) return 'A new pause is only possible 7 days after the previous pause ended.'
  if (msg.includes('invalidemployee')) return 'A wallet in the file is the vault or the USDC contract and cannot be paid.'
  if (msg.includes('duplicatesaprunid')) return 'This SAP run ID was already used. Use a new ID (for example add -v2).'
  if (msg.includes('claimdeadlinepassed')) return 'The claim deadline has passed.'
  if (msg.includes('missingentry')) return 'No salary entry found for this wallet.'
  if (msg.includes('insufficientsurplus')) return 'Amount exceeds the unreserved surplus.'
  if (msg.includes('insufficient funds') || msg.includes('exceeds balance')) return 'Insufficient USDC balance for this transaction or gas.'
  if (msg.includes('network') || msg.includes('timeout')) return 'Network issue. Check your connection and retry.'
  if (msg.includes('reverted')) return 'Transaction reverted. Check the payrun state and try again.'
  return 'Something went wrong. Please try again.'
}
