# Proposal: Exploring USDC Salary Payments on Arc, Alongside SAP ERP

Prepared for: Provincial Electricity Authority (PEA), Thailand
Status: exploratory proposal and working prototype (Arc Testnet only, no real funds)

## Purpose

PEA would like to explore whether USDC on the Arc network can serve as an alternative way to deliver salary payments, while SAP ERP remains the system of record for payroll. This document describes what a prototype does today and what must be evaluated before any real use.

## How it would work

1. **SAP ERP calculates payroll.** Salaries, deductions and payroll records stay in SAP. SAP remains the source of truth.
2. **Payroll data is exported from SAP and imported into the payroll application.** HR exports the payroll result report (XLSX or CSV) and uploads it in the browser. This is a manual, file-based step. There is no live connection to SAP, and nothing is written back to SAP automatically.
3. **Amounts are converted using an exchange rate that HR enters.** SAP amounts in Thai Baht are converted to USDC at a rate the treasury team provides. The application does not fetch market rates and does not buy USDC. PEA must acquire the USDC separately through an approved channel.
4. **The payrun is checked and funded.** The application checks the file (employee wallets, amounts, duplicates, totals). The employee count and total are recorded before upload, and the payrun cannot be opened unless the uploaded data matches them. PEA then deposits USDC into a payroll smart contract, which refuses to open a payrun that is not fully funded.
5. **Employees claim their own salary.** Each employee connects the wallet registered by HR and claims. The USDC is sent from the contract to that wallet on the Arc network. PEA does not push payments to employees.
6. **Reconciliation is done by PEA.** Claims are visible on a public block explorer. Matching them to SAP records is currently a manual process.

SAP ERP stays the main payroll management system. USDC on Arc is only the delivery channel.

## What the prototype provides today

- Import of SAP exports (XLSX, SAP HTML-style XLS, CSV, text), including SAP number formats, total rows, Windows-874 and UTF-16 text, and a separate employee-to-wallet list (SAP has no wallet field).
- Row-by-row validation and rejection of ambiguous or negative amounts, mixed currencies, invalid or shared wallets.
- Control totals, full-funding check before a payrun opens, and a claim deadline.
- Opened payruns cannot be revoked per employee. Corrections require a new payrun. Pausing claims is possible but limited, and it freezes claim deadlines.
- Thai and English interface.
- Automated tests of the contract logic and automated security review. **No independent professional audit has been done.**

## What the prototype does not do

- It does not connect to SAP directly, and does not post payment results back to SAP.
- It does not convert Baht to USDC, source exchange rates, or turn USDC back into Baht for employees.
- It does not perform identity checks (KYC) on wallets. HR is responsible for the employee-to-wallet mapping.
- It does not run on a production network. It is deployed on Arc Testnet with test funds only. Moving to mainnet involves real funds that cannot be recovered once sent, and it needs independent review first.

## Points that differ from a simple "SAP pays USDC" picture

- **Employees pull, PEA does not push.** Employees must act to receive salary. Unclaimed funds can be released back to PEA after the claim deadline.
- **Salaries are public on the blockchain.** Wallet addresses and amounts are visible to anyone. SAP employee IDs are published only as hashes. This needs a privacy (PDPA) assessment before any real use.
- **Employees carry exchange-rate risk.** USDC tracks the US dollar, not the Thai Baht, so the Baht value of a salary can change after payment.
- **Employees need wallets and a way to spend.** They need a wallet, a small USDC balance for network fees (on Arc, fees are paid in USDC), and a route to convert USDC to Baht.
- **Key control matters.** One administrator wallet controls the contract. For real use, control should sit with a multi-signature wallet and approved officers.

## To be evaluated before any real use

- **Legal and regulatory (Thailand):** whether salary may be paid in USDC under Thai labour law, Bank of Thailand and SEC rules on digital assets, and rules for state enterprises. The prototype does not establish compliance.
- **Finance and tax:** accounting treatment of USDC, withholding tax and social security calculations, auditor requirements, and how payments are reconciled to SAP.
- **Cybersecurity:** key management, access control, independent smart contract audit, incident response, and exposure to the USDC issuer's ability to freeze funds.
- **Data protection:** public disclosure of pay data and wallet addresses.
- **Operations and employee impact:** voluntary opt-in, wallet support, conversion to Baht, and a fallback to bank payment.
- **Procurement and internal policy:** approvals and vendor assessments.

## Suggested next step

Run a small, voluntary pilot on the test network with non-production data, in parallel with normal bank payroll. Complete the legal, tax, privacy and security reviews above before any mainnet decision.
