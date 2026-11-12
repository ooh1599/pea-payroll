import { useMemo } from 'react'
import { erc20Abi, type Address } from 'viem'
import { useReadContract, useReadContracts } from 'wagmi'
import { CHAIN_ID, USDC_ADDRESS, VAULT_ADDRESS, toRunData, vaultAbi, type RawRun, type RunData } from '@/lib/payroll'

const POLL_MS = 8000

export function useVault() {
  const base = { address: VAULT_ADDRESS, abi: vaultAbi, chainId: CHAIN_ID } as const
  const enabled = Boolean(VAULT_ADDRESS)

  const summary = useReadContracts({
    allowFailure: false,
    query: { enabled, refetchInterval: POLL_MS },
    contracts: [
      { ...base, functionName: 'owner' },
      { ...base, functionName: 'paused' },
      { ...base, functionName: 'totalOwed' },
      { ...base, functionName: 'runCount' },
      { address: USDC_ADDRESS, abi: erc20Abi, chainId: CHAIN_ID, functionName: 'balanceOf', args: [VAULT_ADDRESS ?? '0x0000000000000000000000000000000000000000'] },
      { ...base, functionName: 'claimsPaused' },
    ],
  })

  const runCount = summary.data ? Number(summary.data[3]) : 0
  const runIds = useMemo(() => Array.from({ length: runCount }, (_, i) => i + 1), [runCount])

  const runsQuery = useReadContracts({
    allowFailure: false,
    query: { enabled: enabled && runCount > 0, refetchInterval: POLL_MS },
    contracts: runIds.flatMap((id) => [
      { ...base, functionName: 'getRun' as const, args: [BigInt(id)] as const },
      { ...base, functionName: 'effectiveDeadline' as const, args: [BigInt(id)] as const },
    ]),
  })

  const runs: RunData[] = useMemo(
    () => {
      const data = runsQuery.data
      if (!data) return []
      return runIds.map((id, i) => toRunData(id, data[i * 2] as RawRun, data[i * 2 + 1] as bigint)).reverse()
    },
    [runsQuery.data, runIds],
  )

  return {
    owner: summary.data?.[0],
    paused: summary.data?.[1],
    claimsPaused: summary.data?.[5],
    totalOwed: summary.data?.[2],
    vaultBalance: summary.data?.[4],
    runs,
    runCount,
    isLoading: summary.isLoading || runsQuery.isLoading,
    isError: summary.isError || runsQuery.isError,
  }
}

export interface MyEntry {
  run: RunData
  amount: bigint
  claimed: boolean
  revoked: boolean
  claimable: bigint
}

export function useMyEntries(address: Address | undefined, runs: RunData[]) {
  const ordered = useMemo(() => [...runs].sort((a, b) => a.id - b.id), [runs])
  const base = { address: VAULT_ADDRESS, abi: vaultAbi, chainId: CHAIN_ID } as const

  const query = useReadContracts({
    allowFailure: false,
    query: { enabled: Boolean(VAULT_ADDRESS && address && ordered.length > 0), refetchInterval: POLL_MS },
    contracts: ordered.flatMap((run) => [
      { ...base, functionName: 'getEntry' as const, args: [BigInt(run.id), address ?? '0x0000000000000000000000000000000000000000'] as const },
      { ...base, functionName: 'claimable' as const, args: [BigInt(run.id), address ?? '0x0000000000000000000000000000000000000000'] as const },
    ]),
  })

  const entries: MyEntry[] = useMemo(() => {
    if (!query.data) return []
    const out: MyEntry[] = []
    ordered.forEach((run, i) => {
      const entry = query.data[i * 2] as { amount: bigint; claimed: boolean; revoked: boolean }
      const claimable = query.data[i * 2 + 1] as bigint
      if (entry.amount === 0n) return
      out.push({ run, amount: entry.amount, claimed: entry.claimed, revoked: entry.revoked, claimable })
    })
    return out.reverse()
  }, [query.data, ordered])

  return { entries, isLoading: query.isLoading }
}

export function useUsdcWalletBalance(address: Address | undefined) {
  return useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    chainId: CHAIN_ID,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: Boolean(address), refetchInterval: POLL_MS },
  })
}

export function useAllowance(owner: Address | undefined) {
  return useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    chainId: CHAIN_ID,
    functionName: 'allowance',
    args: owner && VAULT_ADDRESS ? [owner, VAULT_ADDRESS] : undefined,
    query: { enabled: Boolean(owner && VAULT_ADDRESS) },
  })
}
