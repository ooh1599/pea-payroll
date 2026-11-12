import { useState } from 'react'
import { isAddress, type Address } from 'viem'
import { useAccount } from 'wagmi'
import { Pause, Play, Vault } from 'lucide-react'
import { useFunding } from '@/hooks/useFunding'
import { useLang } from '@/lib/i18n'
import { VAULT_ADDRESS, fmtUsdc, vaultAbi } from '@/lib/payroll'
import { parseUsdc } from '@/onchain-money'
import { Btn, Card, Field, SectionTitle, Stat, inputClass } from '@/components/ui'

interface Props {
  vaultBalance: bigint
  totalOwed: bigint
  paused: boolean
}

function safeParse(value: string): bigint | null {
  try {
    const v = parseUsdc(value)
    return v > 0n ? v : null
  } catch {
    return null
  }
}

export function TreasuryCard({ vaultBalance, totalOwed, paused }: Props) {
  const { t } = useLang()
  const { address } = useAccount()
  const { fundVault, run, busy, stage, walletBalance } = useFunding()
  const [fundAmount, setFundAmount] = useState('')
  const [withdrawAmount, setWithdrawAmount] = useState('')
  const [withdrawTo, setWithdrawTo] = useState('')

  const surplus = vaultBalance > totalOwed ? vaultBalance - totalOwed : 0n
  const fundRaw = safeParse(fundAmount)
  const withdrawRaw = safeParse(withdrawAmount)
  const toAddress = (withdrawTo || address || '')
  const stageLabel = stage === 'wallet' ? t('ยืนยันในกระเป๋า…', 'Confirm in wallet…') : stage === 'confirming' ? t('กำลังยืนยัน…', 'Confirming…') : null

  return (
    <Card>
      <SectionTitle
        icon={<Vault className="size-4" aria-hidden />}
        title={t('คลังเงินเดือน (Vault)', 'Payroll vault')}
        hint={t('เงินที่จองไว้สำหรับงวดที่เปิดแล้วจะถอนออกไม่ได้ ถอนได้เฉพาะส่วนเกิน', 'Funds reserved for open payruns cannot be withdrawn. Only the surplus can.')}
      />
      <div className="grid grid-cols-3 gap-2.5">
        <Stat label={t('ยอดใน Vault', 'In vault')} value={fmtUsdc(vaultBalance)} sub="USDC" />
        <Stat label={t('จองไว้จ่าย', 'Reserved')} value={fmtUsdc(totalOwed)} sub="USDC" />
        <Stat label={t('ส่วนเกิน', 'Surplus')} value={fmtUsdc(surplus)} sub="USDC" />
      </div>

      <div className="mt-5 grid gap-4 sm:grid-cols-2">
        <div>
          <Field label={t('เติม USDC เข้า Vault', 'Add USDC to vault')} hint={walletBalance !== undefined ? `${t('ในกระเป๋าคุณ', 'In your wallet')}: ${fmtUsdc(walletBalance)} USDC` : undefined}>
            <input className={inputClass} inputMode="decimal" placeholder="0.00" value={fundAmount} onChange={(e) => setFundAmount(e.target.value.replace(/[^0-9.]/g, ''))} />
          </Field>
          <Btn className="mt-2 w-full" variant="ghost" loading={busy} disabled={!fundRaw} onClick={() => void fundVault(fundRaw!).then((ok) => ok && setFundAmount(''))}>
            {stageLabel ?? t('เติมเงิน', 'Add funds')}
          </Btn>
        </div>
        <div>
          <Field label={t('ถอนส่วนเกิน', 'Withdraw surplus')} hint={`${t('ถอนได้สูงสุด', 'Max')}: ${fmtUsdc(surplus)} USDC`}>
            <input className={inputClass} inputMode="decimal" placeholder="0.00" value={withdrawAmount} onChange={(e) => setWithdrawAmount(e.target.value.replace(/[^0-9.]/g, ''))} />
          </Field>
          <input className={`${inputClass} mono mt-2`} placeholder={address ?? '0x…'} value={withdrawTo} onChange={(e) => setWithdrawTo(e.target.value.trim())} aria-label={t('ส่งไปที่', 'Send to')} />
          <Btn
            className="mt-2 w-full"
            variant="ghost"
            loading={busy}
            disabled={!withdrawRaw || withdrawRaw > surplus || !isAddress(toAddress)}
            onClick={() =>
              void run(
                { address: VAULT_ADDRESS!, abi: vaultAbi, functionName: 'withdrawSurplus', args: [toAddress as Address, withdrawRaw!] },
                t('ถอนส่วนเกินแล้ว', 'Surplus withdrawn.'),
              ).then((r) => r && setWithdrawAmount(''))
            }
          >
            {t('ถอน', 'Withdraw')}
          </Btn>
        </div>
      </div>

      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-2xl p-3.5 inner">
        <div className="text-xs text-pretty" style={{ color: 'var(--ink-2)' }}>
          {paused
            ? t('การเคลมถูกพักอยู่ พนักงานเคลมไม่ได้จนกว่าจะเปิดใหม่', 'Claims are paused. Employees cannot claim until you resume.')
            : t('พักการเคลมชั่วคราวได้ในกรณีพบข้อมูลผิดพลาด', 'Pause claims temporarily if you spot a data error.')}
        </div>
        <Btn size="sm" variant={paused ? 'primary' : 'ghost'} disabled={busy} onClick={() => void run({ address: VAULT_ADDRESS!, abi: vaultAbi, functionName: paused ? 'unpause' : 'pause' })}>
          {paused ? <Play className="size-3.5" aria-hidden /> : <Pause className="size-3.5" aria-hidden />}
          {paused ? t('เปิดให้เคลมอีกครั้ง', 'Resume claims') : t('พักการเคลม', 'Pause claims')}
        </Btn>
      </div>
    </Card>
  )
}
