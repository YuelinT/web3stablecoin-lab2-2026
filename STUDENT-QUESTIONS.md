# STUDENT-QUESTIONS.md — Discussion questions (submit with your repo)

Answer directly under each question. 150–300 words each — **reasoning over length**.

---

## A. Permission design

**A1.** The vault holds `MINTER_ROLE`, so it can `burn` any user's balance. Explain why that is a risk, then write out how you would change `Vault` and `SimpleStablecoin` to remove it.

> Your answer:
> Allowing the vault to hold MINTER_ROLE is risky because the role controls both minting and burn(address,uint256). The vault can therefore destroy any user’s sUSD without that user’s approval. If the vault is compromised, upgraded maliciously, or controlled by a dishonest administrator, users’ balances could be confiscated even when they did nothing wrong. An unauthorized burn would reduce totalSupply() while leaving collateral in the vault, so the accounting invariant might still look safe even though a user has lost funds.
>
> I would separate minting from burning. In SimpleStablecoin, MINTER_ROLE should authorize only mint. I would replace burn(address,uint256) with burn(uint256), which burns only the caller’s own balance. In Vault.redeem, the user would first approve the vault to spend a chosen amount of sUSD. The vault would then call transferFrom(msg.sender, address(this), amount), receive the user-authorized tokens, and burn its own balance. Finally, it would return the corresponding collateral. This design means the vault cannot burn tokens that a user has not explicitly approved and transferred. It preserves redemption while removing the vault’s unilateral power over every user balance.





**A2.** In this contract `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE` and `PAUSER_ROLE` all go to the same address. How would you split them in production, and who holds each?

> Your answer:
> In production, the three roles should be separated according to the principles of least privilege and separation of duties. No single wallet should be able to administer permissions, mint tokens, and control emergency actions.
>
> `DEFAULT_ADMIN_ROLE` should be held by a high-security governance multisignature, such as a three-of-five wallet whose signers belong to independent teams. It should only grant and revoke roles, rotate compromised keys, and approve major permission changes. Administrative transactions should normally pass through a timelock so that users and security monitors can detect unexpected changes before they take effect. Because this role can control the entire permission system, its keys should be stored offline where possible and used rarely. A two-step, delayed admin-transfer mechanism would further reduce the risk of accidental or malicious transfers.
>
> `MINTER_ROLE` should be assigned only to an audited vault contract, never directly to an employee or ordinary externally owned account. The vault should mint sUSD atomically only after receiving and recording valid collateral. It should also enforce per-transaction or daily minting limits. Role changes and unusually large mint events should trigger immediate monitoring alerts, and governance should be able to revoke the role during an incident.
>
> `PAUSER_ROLE` should be held by a separate emergency security council or limited-purpose multisignature that can respond quickly. It should be able to pause affected operations but must not mint tokens or administer roles. Ideally, pausing could happen immediately, while unpausing would require approval from the governance multisignature after investigation and testing. This may require separating pause and unpause permissions. Together, role separation, multisignatures, timelocks, limits, monitoring, and key rotation prevent one compromised credential from taking control of the entire stablecoin system.


---

## B. Pausing and redemption

**B1.** `_update` is the single entry point for every balance change, so `pause()` freezes transfers, minting and redemption together. If you wanted "pause transfers but **allow redemption**", how would you change it? Give the approach — full code not required.

> Your answer:
> The current contract applies whenNotPaused to _update, and every mint, transfer, and burn passes through that function. As a result, pausing blocks all three operations. To pause transfers while preserving redemption, I would remove the blanket whenNotPaused modifier and make _update distinguish between the different balance changes.
>
> In ERC-20, a normal transfer has non-zero from and to addresses, minting has from == address(0), and burning has to == address(0). While the contract is paused, _update should reject updates whose to address is not zero. This would block ordinary transfers and new minting while allowing burns to continue. Because redemption burns sUSD before returning collateral, users could still exit the system during an emergency.
>
> Burn operations still require the necessary authorization. Following the improvement proposed in A1, the vault can execute burns by leveraging the user's allowance and a dedicated `burnFrom` path; thus, even if burning is permitted during a pause, the vault cannot arbitrarily deduct a user's balance. Furthermore, I will include test cases to verify this logic: transfers and minting operations should revert when the contract is paused; authorized redemptions should execute successfully; and unauthorized burn attempts should continue to fail.



**B2.** In 2008, when a money-market fund "broke the buck", redemptions were frozen for days. In 2023 USDC depegged to $0.87 after a reserve bank failed, but redemptions were **not** shut. Compare the two responses — what does closing the redemption channel, or leaving it open, do to a stablecoin?

> Your answer:
> Freezing redemptions can mitigate runs and provide institutions with time to value or sell illiquid assets. Much like the suspension of redemptions by money market funds, this approach may protect remaining reserves in the short term. However, it leaves holders trapped, unable to convert their shares into the value of the underlying assets. As standard arbitrage mechanisms cease to function, prices on the secondary market may fall even further. Consequently, while freezing redemptions may temporarily safeguard liquidity, it risks severely damaging market confidence.
>
> Keeping redemptions open—as was the case during the 2023 USDC incident—helps maintain the link between the token and its reserves. If sUSD falls below one dollar, arbitrageurs can purchase the discounted tokens and then redeem them for a value close to one dollar. This buying demand helps narrow the discount and restore the peg, while also demonstrating that the issuer is both willing and able to meet its obligations.
>
> The disadvantage is that open redemption can accelerate reserve outflows. If reserves are unavailable, illiquid, or worth less than the outstanding supply, a rapid wave of redemptions can exhaust them. Therefore, keeping redemption open is stabilizing only when reserves are credible and accessible. Closing it buys time, but transfers financial risk and uncertainty to token holders.
>
> Overall, keeping redemption open is usually the stronger defence of the peg when reserves are sound, while freezing redemption is an emergency liquidity measure that may preserve assets temporarily but weakens convertibility and market confidence.


---

## C. Depeg analysis

**C1.** Under what conditions does this coin depeg? Distinguish at least two classes of cause, and say how each one shows up in the invariant `totalCollateral() >= totalSupply()`.

> Your answer:
> This type of stablecoin can lose its peg due to at least two distinct categories of failures. For example, an attacker with MINTER_ROLE could mint sUSD without depositing mUSDC, or collateral could be stolen from the vault. In the simple system, this failure appears directly as totalCollateral() < totalSupply(). Some sUSD would no longer have matching collateral, so rational holders would value each token below one dollar. If the collateral itself lost market value, the raw-unit invariant might still pass even though the economic value of the reserves was insufficient. A production invariant would therefore need to compare market values rather than token quantities alone.
>
> The second class is a convertibility or liquidity failure. The contract may still hold enough collateral, but users may be unable to redeem because the system is paused, the redemption contract is broken, the network is unavailable, or the off-chain issuer cannot process withdrawals. In this case, totalCollateral() >= totalSupply() can remain true while the market price falls below one dollar because holders cannot access the collateral and arbitrageurs cannot close the discount.
>
> A blocked minting channel can also cause an upward depeg. If demand rises but users cannot create new sUSD against collateral, the price may exceed one dollar even though the collateral invariant remains satisfied. Therefore, on-chain solvency is necessary but not sufficient to maintain the peg; the system also depends on credible collateral valuation and continuously available minting and redemption channels.



**C2.** Suppose an attacker bribes their way to `MINTER_ROLE`, mints 1,000,000 sUSD out of nothing and redeems it all. Describe the flow of funds, and name the step that could have stopped them.

> Your answer:

> First, the attacker obtains MINTER_ROLE, for example through bribery, administrator-key compromise, or an incorrect role assignment. They then call mint directly and create 1,000,000 sUSD without transferring any mUSDC into the vault. At that moment, totalSupply() increases while totalCollateral() remains unchanged, so the backing invariant is broken.
>
> The attacker can next call Vault.redeem. The vault burns the attacker’s sUSD and transfers an equal amount of mUSDC from its reserves. That collateral was originally deposited by honest users. The contract checks whether the vault currently holds enough collateral, so the attacker cannot redeem more than the available balance in one transaction. However, they can drain all available collateral, leaving honest holders with sUSD that can no longer be fully redeemed.
>
> The best stopping point is before unauthorized minting occurs. DEFAULT_ADMIN_ROLE should be protected by a multisignature wallet and timelock, and MINTER_ROLE should be assigned only to the vault rather than an externally controlled account. The stablecoin could also enforce minting limits or require minting to occur only after the vault records matching collateral. Therefore, securing role assignment and restricting the minting path are more effective protections than relying on a collateral-balance check after unbacked tokens have already been created.



---

## D. Toward RWA

**D1.** Right now the collateral is `MockUSDC` and `totalCollateral()` just reads an on-chain balance — simple and reliable. If the collateral were **US Treasuries**, could this invariant still be written that way? What new problems appear?

> Your answer:

> If the collateral were US Treasuries, the current invariant could not simply compare an on-chain token balance with `totalSupply()`. Treasuries are held through banks, brokers, and custodians, while ownership is established through off-chain legal records. An ERC-20 token may represent a claim on those securities, but its balance alone cannot prove that the underlying Treasuries exist, are held in a segregated account, remain free of other liens, or can legally be used to satisfy stablecoin redemptions.
>
> The system would also face valuation, liquidity, operational, and legal risks. Treasury prices change with interest rates, and their value should include accrued interest while reflecting maturity and settlement dates. Assets that cannot be sold immediately may require a liquidity haircut. Custody fees, pending trades, taxes, and redemption obligations must also be included. Oracle data may become stale or manipulated, auditors may report with a delay, and a custodian may fail. In addition, token holders need a legally enforceable and preferably bankruptcy-remote claim if the issuer becomes insolvent.
>
> I would replace the quantity-based invariant with:
>
> `riskAdjustedReserveValue >= circulatingSupply + pendingRedemptions`
>
> `riskAdjustedReserveValue` would be calculated from independently attested Treasury quantities multiplied by current market prices, plus accrued interest, minus fees, unsettled liabilities, and conservative liquidity haircuts. Custodian records should be reconciled regularly with on-chain issuance, and price data should come from multiple approved sources with freshness limits. If attestations or prices become stale, new minting should stop automatically while controlled redemptions remain available where possible. Therefore, the invariant would become a combined technical, financial, and legal control rather than a simple balance check.



**D2.** If the collateral were **a building**, how would you put it inside this vault? Which off-chain roles or legal structures would you have to introduce?

> Your answer:


> A building cannot be physically transferred into a smart contract, so the vault must hold a legally enforceable claim connected to the property. I would establish a bankruptcy-remote special-purpose vehicle (SPV) that owns the building and is recorded as the legal owner in the land registry. The on-chain token could represent equity in the SPV, a secured loan to it, or a defined beneficial interest in its income and sale proceeds. The token documentation, property title, mortgage, and security agreement must clearly connect the on-chain position to enforceable off-chain rights. Otherwise, the token would only be a digital record with no reliable claim on the building.
>
> Several independent off-chain parties would be required. A trustee or regulated custodian would hold legal documents and act for token holders. A property manager would collect rent, pay taxes, arrange maintenance, manage tenants, and report operating expenses. Independent appraisers would update the property valuation, while auditors would verify ownership, rental income, expenses, mortgages, and other liens. An approved oracle or attestation provider would publish verified valuation and cash-flow data on-chain. Banks would process fiat payments, insurers would cover property risks, and legal counsel, transfer agents, and compliance providers would handle securities law, investor eligibility, KYC/AML, and transfer restrictions.
>
> The vault would also need rules for distributing net rental income, retaining maintenance reserves, applying valuation haircuts, and suspending new minting when reports become stale. If the SPV defaulted, a trustee or security agent would need authority to enforce the mortgage, replace the manager, sell the building, and distribute proceeds according to a predefined priority. Smart contracts could automate token accounting and payments, but ownership, valuation, operation, and enforcement would ultimately remain dependent on legal agreements and trusted off-chain institutions.

---

## E. Tests (Tier 1 required — this is Ex4)

Turn the red tests green in `test/exercises/01_LoopTasks.t.sol` to cover the scenarios below, and write your test function names here:

| Scenario | Your test function name |
|---|---|
| Minting by a non-minter reverts | `test_Ex4_Mint_RevertsForNonMinter` |
| Transfers revert while paused | `test_Ex4_Pause_BlocksTransfers`|
| **Redemption** reverts while paused | `test_Ex4_Pause_BlocksRedeem`|
| An attacker cannot burn someone else's balance | `test_Ex4_AttackerCannotBurnOthersBalance` |
| ...but the vault holding `MINTER_ROLE` can | `test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance`|

That last pair is meant to be read together: the guard is written correctly, but the key was handed to the vault. Keep it in mind when you answer A1.

Now write one more scenario you consider **most likely to be attacked**, and say why you picked it:

> Your answer:

> The scenario I consider most likely to be attacked is the compromise of the administrator account that controls role assignment. Although an ordinary attacker cannot mint sUSD, an attacker who gains control of the administrator key can grant themselves MINTER_ROLE. They can then mint a large amount of unbacked sUSD without depositing collateral, causing totalSupply() to become much greater than totalCollateral(). Ex3 demonstrates this outcome directly. Because this attack can drain collateral and destroy confidence in the stablecoin, the administrator role should be protected by a multisignature wallet, separated from operational roles, monitored for unexpected role changes, and subject to a timelock or emergency revocation process.