# Payroll Vault

Pay salaries in USDC from SAP payroll data. HR uploads a SAP export, funds a vault, and each employee claims their own salary from their own wallet.

Built with [Arc Studio](https://studio.arc.io)

## What it does

- Employer / HR: import the SAP payroll export, review validation errors row by row, save it as a draft payrun, fund the vault and open the payrun.
- Employees: connect a wallet, see payslips for opened payruns and claim USDC directly to that wallet.
- Employer controls: claim deadlines, revoking an employee while a payrun is still a draft, pausing claims, releasing expired amounts and withdrawing unreserved surplus.
- Thai and English interface.

## Importing from SAP ERP

Export the payroll results report from SAP (Export > Spreadsheet or Local file). Supported: `.xlsx`, SAP's HTML-style `.xls`, `.csv`, `.txt` (comma, semicolon, tab or pipe separated; UTF-8, UTF-16 and Windows-874).

| Column (SAP name or equivalent) | Meaning |
| --- | --- |
| `PERNR` / `Pers.No.` / `employee_id` | Personnel number. Leading zeros are ignored. Published only as a hash |
| `BETRG` / `Amount` / `net_pay` | Net amount. SAP formats such as `45.000,00` and `100-` are understood |
| `WAERS` / `Crcy` (optional) | Currency. If missing, pick it in the form |
| `ENAME` / `Name` (optional) | Shown in the preview only |
| `wallet_address` (optional) | Employee wallet. If missing, wallets come from the wallet directory |

- SAP has no wallet field. Upload a wallet directory (employee ID and wallet) once; it is stored in the browser and reused for every payrun.
- Salaries in a local currency (for example THB) are converted to USDC with an exchange rate you enter. The rate is recorded in the payrun name.
- Title lines and total rows in the SAP list are skipped. Lines for the same employee are merged into one payment.
- Ambiguous amounts such as `1,234`, negative amounts, mixed currencies and invalid wallets are rejected with the row number.
- Files are processed in the browser and are not sent to a server.

Salary amounts and wallet addresses are public on the blockchain.

## Safety rules

- Every payrun is created with the employee count and total from the SAP file. It can only be opened when the uploaded rows match those control totals.
- A payrun can only be opened when the vault holds enough USDC to cover every open payrun.
- Opened payruns cannot be revoked per employee. Corrections go into a new payrun.
- Pausing claims freezes claim deadlines, so a pause never makes salaries expire.
- The owner should be a multisig wallet. USDC issuer restrictions on the vault address would also block payouts.
- Ambiguous amounts such as `1,234` and wallets with a wrong checksum are rejected during upload.

## Tech stack

Vite, React, TypeScript, Tailwind CSS, wagmi, viem, ConnectKit, Solidity (Foundry, OpenZeppelin). Network: Arc Testnet.

## Development

Prerequisites: Bun, Foundry.

```bash
bun install
bun run dev          # start the app
bun run check        # lint and typecheck
bun run contracts:build
bun run contracts:test
```

### Environment variables

| Name | Purpose |
| --- | --- |
| `VITE_PAYROLL_VAULT_ADDRESS` | Address of the deployed `PayrollVault` contract |

Contract source: `contracts/PayrollVault.sol`.
