# Demo cheat sheet: Fabric Governance and Security (OSFI, Nov 3 2026)
**SYNTHETIC DATA · for training only · no real customer data.** Workspace **FGD-Security-Demo**. Full steps are in README section 5.

| # | Demo (time) | Profile(s) | 3 clicks | Expected result |
|---|---|---|---|---|
| D1 | Identity and tenant (3') | Presenter | ① Workspace > **Manage access** ② hover sg-fgd-analysts ③ Admin portal > Tenant settings > "service principals" | Groups only. SP setting scoped to **sg-fgd-automation**. Copilot/agent scoped to groups. |
| D2 | Ingestion (4') | Presenter | ① sqldb_core_banking > **Monitor replication** ② lh_bronze > shortcut **Properties** ③ pl_daily_load > **Run** / run history + activity identity | 3 tables replicating. customers/accounts are shortcuts (no copy, inherit target permissions). Pipeline succeeded. |
| D3 | OneLake security (4') | Presenter > Olivia > Dana | ① lh_silver > **Manage OneLake security** > Enable ② role **ReaderOn** (sg-fgd-province-on): row `province='ON'` + remove **sin, date_of_birth**; delete **DefaultReader** ③ SQL endpoint (User identity) `SELECT province, COUNT(*) FROM dbo.customer GROUP BY province` | Olivia: **ON only**; `SELECT *` fails with *permission denied on column sin* (= column rule working), list columns instead. **Dana (Contributor): all 13 + sin = lead finding** (workspace roles bypass OneLake roles). |
| D4 | Data engineering (3') | Dana > Olivia (sandbox) | ① nb_03 **Run all** as Dana ② FGD-Analyst-Sandbox nb_03 **Run all** as Olivia ③ scroll to Key Vault cell | Dana: 13 provinces, sin, write ALLOWED. Olivia: ON / no sin **or ACCESS DENIED (fails closed)**, write DENIED. |
| D5 | Warehouse T-SQL (4') | Presenter > Olivia > Sam | ① run sql/31 **BLOCKS 1–4** ② Olivia runs **BLOCK 5** ③ Sam runs **BLOCK 5** | Olivia: ON rows, email `aXXX@XXXX.com`, SIN **denied**, sec **denied**, dim_account unfiltered (per-table RLS). Sam: all, unmasked, SIN. |
| D6 | Semantic model / Power BI (3') | Presenter > Olivia | ① sm_gold_banking > **Security** (Province DAX + OLS) ② **Test as role** > Other user = olivia ③ Olivia opens **rpt_loan_portfolio** | ON only (~1,900 customers). Steward-view visual can't render. *Write permission = RLS doesn't apply.* |
| D7 | Data agent and Fabric IQ (4') | Olivia > Sam > Presenter | ① Olivia: "customers and loan amount by province?" + "SIN of top 5 borrowers?" ② Sam: same ③ agent **Share** dialog (+ onto_banking bindings) | Olivia: ON only, SIN not available. Sam: all + SIN. **Sharing an agent ≠ sharing data.** |
| D8 | Labels and Purview (4') | Presenter | ① lh_silver (+ wh_gold) > **Sensitivity label** ② **Lineage** > report > **Export data** to Excel ③ **Purview hub** + Purview **Audit** search | Label inherited downstream. Excel file carries the label. Audit shows rehearsal events. |
| — | Network, CI/CD | slides | — | Tenant-wide impact, so not live. |

**Before D1:** capacity on · 6 profiles signed in · pl_daily_load last run green · sql/39 reset run · DefaultReader present (live mode) · nb_03 sessions pre-started (Dana and Olivia) · report pre-warmed · fallback screenshots open in a separate window.
**Never on screen:** `scripts/out/fgd-credentials.csv`, client secrets, the Admin portal's other tenant settings for longer than needed.
