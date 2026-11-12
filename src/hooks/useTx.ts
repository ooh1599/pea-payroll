import { useCallback, useState } from 'react'
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import type { Abi, Address, Hash, TransactionReceipt } from 'viem'
import { CHAIN_ID, parseErr } from '@/lib/payroll'

export interface TxRequest {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
}

export type TxStage = 'idle' | 'wallet' | 'confirming'

export interface TxResult {
  hash: Hash
  receipt: TransactionReceipt
}

/** Sends one contract write, waits for the real receipt, and reports honest stages. */
export function useTx() {
  const { chainId } = useAccount()
  const { switchChainAsync } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()
  const publicClient = usePublicClient({ chainId: CHAIN_ID })
  const queryClient = useQueryClient()
  const [stage, setStage] = useState<TxStage>('idle')
  const [lastHash, setLastHash] = useState<Hash | undefined>()

  const run = useCallback(
    async (req: TxRequest, successMessage?: string): Promise<TxResult | null> => {
      if (!publicClient) return null
      try {
        setStage('wallet')
        if (chainId !== CHAIN_ID) await switchChainAsync({ chainId: CHAIN_ID })
        const hash = await writeContractAsync({ ...req, chainId: CHAIN_ID })
        setStage('confirming')
        setLastHash(hash)
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        if (receipt.status !== 'success') throw new Error('Transaction reverted')
        await queryClient.invalidateQueries()
        if (successMessage) toast.success(successMessage)
        return { hash, receipt }
      } catch (error) {
        const message = parseErr(error)
        if (message) toast.error(message)
        return null
      } finally {
        setStage('idle')
      }
    },
    [chainId, publicClient, queryClient, switchChainAsync, writeContractAsync],
  )

  return { run, stage, busy: stage !== 'idle', lastHash }
}
