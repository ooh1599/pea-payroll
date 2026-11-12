import { useCallback } from 'react'
import { erc20Abi } from 'viem'
import { useAccount } from 'wagmi'
import { toast } from 'sonner'
import { useAllowance, useUsdcWalletBalance } from '@/hooks/usePayroll'
import { useTx } from '@/hooks/useTx'
import { useLang } from '@/lib/i18n'
import { USDC_ADDRESS, VAULT_ADDRESS, fmtUsdc, vaultAbi } from '@/lib/payroll'

/** Approve (when needed) and deposit USDC into the vault, using the connected wallet. */
export function useFunding() {
  const { t } = useLang()
  const { address } = useAccount()
  const tx = useTx()
  const { data: allowance, refetch: refetchAllowance } = useAllowance(address)
  const { data: walletBalance } = useUsdcWalletBalance(address)

  const fundVault = useCallback(
    async (amount: bigint): Promise<boolean> => {
      if (!VAULT_ADDRESS || amount <= 0n) return true
      if (walletBalance !== undefined && walletBalance < amount) {
        toast.error(t(`USDC ในกระเป๋าไม่พอ ต้องใช้ ${fmtUsdc(amount)} USDC`, `Not enough USDC in your wallet. You need ${fmtUsdc(amount)} USDC.`))
        return false
      }
      const current = allowance ?? (await refetchAllowance()).data ?? 0n
      if (current < amount) {
        const approved = await tx.run({ address: USDC_ADDRESS, abi: erc20Abi, functionName: 'approve', args: [VAULT_ADDRESS, amount] })
        if (!approved) return false
      }
      const funded = await tx.run({ address: VAULT_ADDRESS, abi: vaultAbi, functionName: 'fund', args: [amount] }, t('เติมเงินเข้า Vault แล้ว', 'Vault funded.'))
      return funded !== null
    },
    [allowance, refetchAllowance, t, tx, walletBalance],
  )

  return { fundVault, walletBalance, ...tx }
}
