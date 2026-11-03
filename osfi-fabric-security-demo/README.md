# Microsoft Fabric Governance and Security: OSFI demo kit

> **SYNTHETIC DATA · for training only · no real customer data.**
> Every name, email, SIN-like value and balance is generated. SIN-like values are built to **fail** the Luhn check, so none can be a real SIN.

| | |
|---|---|
| Session | "Microsoft Fabric Governance and Security" for OSFI (Teams). Tue Nov 3 2026, 9:30–11:00 content, then 30 min Q&A |
| Presenter | Nicolas Soukoff, Microsoft Solution Engineer |
| Format | Presenter-run live demos. The audience doesn't need Fabric access. 8 demos of 2–4 min each, all on one data path. |
| Self-contained | Builds everything from scratch in **any** tenant. No dependency on earlier sessions, workspaces, lakehouses or repos. |

---

## 1. What the kit shows: one data path, a control at every hop

```
 sqldb_core_banking (SQL database in Fabric)          CSV files (simulated external drop)
   dbo.customers / accounts / transactions               loan_applications_YYYY-MM-DD.csv x3
        │ automatic replication to OneLake (Delta)              │ nb_01_ingest_files
        ▼                                                       ▼
 lh_bronze  ── shortcuts: customers, accounts ──►  Files/landing/... + table loan_applications_raw
        │ nb_02_bronze_to_silver   (pl_daily_load = nb_01 ► nb_02)
        ▼
 lh_silver  (customer, account, loan, transaction_monthly)      ◄── OneLake security: roles + RLS + CLS   [D3, D4]
        │ cross-database CTAS (sql/30)
        ▼
 wh_gold    (gold.dim_customer, dim_account, fact_loan, fact_transaction_monthly; sec.user_province)
                                                                 ◄── T-SQL OLS / RLS / CLS / DDM            [D5]
        │ Direct Lake
        ▼
 sm_gold_banking  (role Province: dynamic RLS + OLS on sin, date_of_birth; role Steward)   [D6]
        ├──► rpt_loan_portfolio (report)                                                  [D6]
        ├──► da_loan_portfolio  (Fabric data agent)                                       [D7]
        └──► onto_banking       (Fabric IQ ontology, preview, optional)                   [D7]

 Around it: Entra groups + tenant settings [D1] · ingestion identity [D2] · sensitivity labels, Purview hub, audit [D8]
 Slide-only: network isolation, CI/CD (tenant-wide impact, see section 6)
```

### Personas: one browser profile each

| Persona (UPN `<name>@<tenantDomain>`) | Browser profile | Groups | Workspace role | lh_silver (OneLake security) | wh_gold (T-SQL) | sm_gold_banking | What they should see |
|---|---|---|---|---|---|---|---|
| Presenter | **FGD Presenter** | sg-fgd-admins | Admin | bypasses roles | db_owner | Write (RLS doesn't apply) | Everything |
| fgd.dana.engineer | **FGD Dana** | sg-fgd-engineers | Contributor | **bypasses roles (lead finding)** | db_owner | Write (RLS doesn't apply) | Everything |
| fgd.olivia.analyst | **FGD Olivia** | sg-fgd-analysts, sg-fgd-province-on | Viewer | reader_on: ON rows, no sin/DOB | ON rows, masked email, SIN denied | Province role: ON, no SIN/DOB | Ontario only |
| fgd.quentin.analyst | **FGD Quentin** | sg-fgd-analysts, sg-fgd-province-qc | Viewer | reader_qc: QC rows | QC rows, masked, SIN denied | Province role: QC | Quebec only |
| fgd.sam.steward | **FGD Sam** | sg-fgd-stewards | Viewer | steward_all: all | all rows, unmasked, SIN visible | Steward role: all | Everything, read-only |
| fgd.aaron.auditor | **FGD Aaron** | sg-fgd-auditors | Viewer | no role, no data | denied on gold and sec | no role, no data | Metadata, lineage, audit only |

Other groups: `sg-fgd-automation` (holds the optional service principal `sp-fgd-automation`; used to scope the "service principals can use Fabric APIs" tenant setting).

---

## 2. Prerequisites

| Need | Detail |
|---|---|
| Capacity | Fabric **F-SKU F2 or larger (F4 recommended)**, ideally in **Canada Central** (data-residency talking point). Not paused. Note the capacity id (Admin portal > Capacity settings > Fabric capacity > your capacity). |
| Fabric rights | Fabric administrator (for tenant settings), plus capacity admin or contributor (to assign the workspace). |
| Entra rights | User Administrator + Groups Administrator (+ Application Administrator for the optional service principal), or Global Administrator in a demo tenant. |
| Purview | Sensitivity labels published to the presenter (any taxonomy, e.g. "Confidential"). Audit (Standard) on, which is the default. |
| PowerShell 7 | `pwsh` 7.2+ |
| Modules | `Install-Module Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Applications, Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser`  ·  `Install-Module Az.Accounts -Scope CurrentUser`  ·  `Install-Module SqlServer -MinimumVersion 22.0.0 -Scope CurrentUser` |
| Browser | Microsoft Edge (or Chrome) with **6 profiles** (section 4, S15). An InPrivate window is fine for one extra persona. |

### Licensing (read this)
On capacities **smaller than F64**, every user who **views Power BI content** (report, semantic model, data agent over a semantic model) needs a **Power BI Pro or PPU** licence. Pick one:
1. Assign Pro to the test users: `./01-New-FgdIdentities.ps1 -LicenseSkuPartNumber POWER_BI_PRO` (or assign in the Microsoft 365 admin center). Trial licences also work. **Or**
2. Demo the Power BI part as the presenter with **Test as role / View as** (D6). That needs no persona licence.

Lakehouse, warehouse, notebook and SQL experiences run on the capacity and don't need Pro.

---

## 3. Tenant settings (Admin portal > Tenant settings)

Scope every setting to **specific security groups** where possible. That is part of the D1 story. Setting names change between releases, so search the settings page for the keywords. Allow up to **15 minutes** for changes to apply.

| Setting (search keyword) | Scope for the demo | Why |
|---|---|---|
| Users can create Fabric items | sg-fgd-admins, sg-fgd-engineers (or org-wide in a demo tenant) | Create items |
| **Service principals can use Fabric APIs** (newer tenants may split this into "...call Fabric public APIs" / "...create workspaces, connections and deployment pipelines") | **Specific security groups: sg-fgd-automation** | D1: automation identity is scoped, not tenant-wide |
| SQL database in Fabric (only if your tenant still shows a switch) | sg-fgd-admins, sg-fgd-engineers | sqldb_core_banking |
| OneLake security / OneLake data access roles (only if gated in your tenant) | Enabled | D3, D4 |
| Users can use Copilot and other features powered by Azure OpenAI | sg-fgd-admins, sg-fgd-analysts, sg-fgd-stewards | Data agent (D7) |
| Data sent to Azure OpenAI can be processed outside your capacity's geographic region... | **Decide deliberately.** Turn it on only if Copilot isn't available in your capacity region. | OSFI data-residency question: be ready to explain it |
| Users can create and share Data agent items (preview) | sg-fgd-admins (create); sharing to analysts/stewards | D7 |
| Fabric IQ / Ontology (preview) | sg-fgd-admins | D7 optional |
| Allow users to apply sensitivity labels for content | sg-fgd-admins (or org) | D8 |
| Apply sensitivity labels from data sources to their data in Power BI | Enabled | D8 |
| Automatically apply sensitivity labels to downstream content | Enabled | D8 inheritance |
| Export to Excel | Enabled (default) | D8: the exported file keeps its label |

---

## 4. Setup (do it the day before; allow about 2.5 h the first time)

```powershell
cd osfi-fabric-security-demo/scripts
Copy-Item config.sample.json config.json      # fill in tenantId, tenantDomain, capacityId, presenterUpn
./01-New-FgdIdentities.ps1 -WhatIf             # preview
./01-New-FgdIdentities.ps1 -LicenseSkuPartNumber POWER_BI_PRO   # licence optional
./02-Deploy-FgdWorkspace.ps1 -CreateAnalystSandbox
./03-Grant-FgdDemoAccess.ps1                   # OPTIONAL "pre-staged" Demo 3 (see S16)
```
Outputs go to `scripts/out/` (`fgd-identities.json`, `fgd-workspace.json`, and `fgd-credentials.csv`, which you **delete after the persona first sign-ins**).

| # | Step | Automated / Click | Time | How |
|---|---|---|---|---|
| S1 | Capacity running, region Canada Central, note the capacity id | Click | 5 min | Azure portal / Admin portal |
| S2 | Tenant settings (section 3) | Click | 15 min (+15 min to apply) | Admin portal |
| S3 | Users, groups, memberships, licences, optional service principal | **Automated**: 01 | 3–5 min | `01-New-FgdIdentities.ps1` |
| S4 | Workspace `FGD-Security-Demo` on the capacity, group role assignments | **Automated**: 02 | 1 min | Click fallback: Workspaces > New workspace > Advanced > License mode: Fabric capacity. Then **Manage access** > add the 5 groups with the roles in section 1. |
| S5 | lh_bronze, lh_silver (leave **Lakehouse schemas unticked**), wh_gold, sqldb_core_banking | **Automated**: 02 | 3 min | Click fallback: New item > Lakehouse / Warehouse / SQL database, with the exact names |
| S6 | Seed sqldb_core_banking, wait for replication | **Automated**: 02 | 5–15 min | Click fallback: open sqldb_core_banking > New query > paste `sql/10_sqldb_seed.sql` > Run. Expect 5,000 / 8,000 / 100,000 rows and `luhn_valid_sins = 0`. Then **Replication > Monitor replication**: 3 tables "Running". |
| S7 | Import nb_01, nb_02, nb_03 (default lakehouse lh_silver) | **Automated**: 02 | 1 min | Click fallback: workspace > Import > Notebook > From this computer > the 3 `.ipynb` files. Attach lh_silver (optional; the notebooks use absolute paths). |
| S8 | Pipeline pl_daily_load (nb_01 ► nb_02), run once | **Automated**: 02 | 10–15 min | Click fallback: New item > Data pipeline > `pl_daily_load` > add 2 **Notebook** activities (nb_01_ingest_files, then nb_02_bronze_to_silver, joined by **On success**) > Save > Run. If shortcuts fail, see the markdown cell in nb_01. |
| S9 | Refresh the lh_silver SQL endpoint, build wh_gold | **Automated**: 02 | 2–3 min | Click fallback: lh_silver > SQL analytics endpoint > **Refresh**. Then wh_gold > New SQL query > paste `sql/30_wh_gold_build.sql`, replace `$(TenantDomain)` with your domain > Run. |
| S10 | Semantic model sm_gold_banking (Direct Lake, TMDL) | **Automated**: 02 | 2 min | See S10 below |
| S11 | Model role members: Province = sg-fgd-analysts, Steward = sg-fgd-stewards | Click | 3 min | sm_gold_banking > ... > **Security** > role > add group > Save |
| S12 | Report rpt_loan_portfolio | Click | 10 min | See S12 below |
| S13 | Data agent da_loan_portfolio | Click | 10 min | See S13 below |
| S14 | Ontology onto_banking (optional, preview) | Click | 15 min | See S14 below |
| S15 | Persona browser profiles, first sign-in, password change, MFA registration | Click | 20–30 min | **Start right after S3.** See S15 below. |
| S16 | Choose the Demo 3 mode: **Live** (default: nothing to do) or **Pre-staged** (enable OneLake security on lh_silver, then run 03) | Click + optional 03 | 5 min | See D3 |
| S17 | Sensitivity label ready: check the presenter can see the label list on an item | Click | 5 min | Item > Settings > Sensitivity label |
| S18 | Full rehearsal, capture fallback screenshots (section 7), then **Reset** (section 8) | Click | 60 min | |

**02 switches:** `-SkipSemanticModel`, `-SkipPipelineRun`, `-CreateAnalystSandbox` (creates `FGD-Analyst-Sandbox` where analysts and stewards are **Contributors**, so Viewer personas can run nb_03 there), `-MirroringTimeoutMinutes`, `-PipelineTimeoutMinutes`. It's idempotent, so rerun it after fixing a failed step. Each failure prints the matching fallback above.

**S10 · semantic model.** 02 uploads `model/` (TMDL) with the wh_gold SQL connection string and warehouse id filled in. Afterwards, open sm_gold_banking and check:
1. **Settings > Gateway and cloud connections / Data source credentials**: Direct Lake connection signed in (OAuth2, **Single sign-on** on, so viewer identity flows to wh_gold).
2. **Refresh** once (Direct Lake framing).
3. Open the model (web modeling) > relationships: dim_customer 1─* dim_account 1─* fact_transaction_monthly; dim_customer 1─* fact_loan. `sec_user_province` is hidden.
4. **Manage roles**: *Province* has the DAX filter on dim_customer: `VAR _p = LOOKUPVALUE(sec_user_province[province], sec_user_province[upn], LOWER(USERPRINCIPALNAME())) RETURN _p = "*" || dim_customer[province] = _p`. OLS sets `sin` and `date_of_birth` to **None**. *Steward* has no filter.

*Click fallback (if the TMDL upload fails):* wh_gold > **New semantic model** > name `sm_gold_banking` > tick gold.dim_customer, dim_account, fact_loan, fact_transaction_monthly, sec.user_province > Confirm. Then create the relationships above and the measures `Customers = DISTINCTCOUNT(dim_customer[customer_id])`, `Total Balance = SUM(dim_account[balance])`, `Loan Amount = SUM(fact_loan[amount])`. Hide sec_user_province. Under **Manage roles**, create *Province* (DAX above; Object security: sin, date_of_birth = None) and *Steward* (no filter).

**S12 · report rpt_loan_portfolio** (presenter): sm_gold_banking > **Create report** (start from scratch).
- Page "Loan portfolio": cards **Customers**, **Loan Amount**, **Total Balance**; clustered bar *province × Loan Amount*; slicer *fact_loan[product]*; table *dim_customer first_name, last_name, email, province* + Loan Amount.
- Page "Steward view" (optional, shows OLS): table *customer_id, sin, date_of_birth*. For olivia this visual can't render, because the fields don't exist for her role.
- Save as **rpt_loan_portfolio** in FGD-Security-Demo.

**S13 · data agent da_loan_portfolio** (presenter): workspace > New item > **Data agent** > `da_loan_portfolio` > add data source **sm_gold_banking** (optionally wh_gold too). Agent instructions:
> You answer questions about a SYNTHETIC Canadian retail bank loan portfolio. Use the sm_gold_banking model. Province values are two-letter Canadian codes (ON, QC, ...). If a field or row isn't available to the current user, say so. Don't infer it. All data is synthetic.

**Publish** > **Share** with sg-fgd-analysts and sg-fgd-stewards. Test one question as the presenter.

**S14 · ontology onto_banking (optional, preview)**: New item > **Ontology** > `onto_banking`. Add entity types *Customer* (key customer_id), *Account* (account_id), *Loan* (application_id). Bind each to lh_silver tables customer / account / loan (or wh_gold gold.*). Add relationships *Customer holds Account* and *Customer applies for Loan* on customer_id. Optionally attach it to the data agent. If the item type isn't in your tenant/region, use the screenshots or slide.

**S15 · browser profiles**: Edge > Profiles > **Add profile** for each persona (name and colour as in section 1). In each profile, open `https://app.fabric.microsoft.com`, sign in with the UPN and initial password from `out/fgd-credentials.csv`, set a new password, and complete MFA registration if security defaults or Conditional Access require it. Then **favourite** the FGD-Security-Demo workspace (and FGD-Analyst-Sandbox for olivia). Set browser zoom to 125% for Teams legibility. **Delete `out/fgd-credentials.csv`** when done.

---

## 5. The 8 live demos (click-by-click)

Run order: D1 → D8. Spark sessions take 1–3 min to start on small capacities, so **start nb_03 sessions in the Dana and Olivia profiles 5 minutes before D4** (run the first cell).

### D1 · Identity and tenant (3 min). Profile: **FGD Presenter**
1. Workspace **FGD-Security-Demo** > **Manage access**.
   *Expected:* only groups: sg-fgd-admins (Admin), sg-fgd-engineers (Contributor), sg-fgd-analysts / sg-fgd-stewards / sg-fgd-auditors (Viewer). No named users.
2. Hover sg-fgd-analysts (or show in the Entra admin center > Groups > Members): olivia and quentin.
3. Settings (gear) > **Admin portal > Tenant settings** > search "service principals".
   *Expected:* "Service principals can use Fabric APIs" is enabled for **specific security groups: sg-fgd-automation**. Also show Copilot and the data agent scoped to groups.
- *Say:* identity is Entra ID (Conditional Access and MFA apply to Fabric). Access is granted to groups, not people. Tenant settings are the first control plane, and they're scoped to groups.

### D2 · Ingestion (4 min). Profile: **FGD Presenter**
1. Open **sqldb_core_banking** > **Replication** > **Monitor replication**.
   *Expected:* dbo.customers, dbo.accounts and dbo.transactions are Running, with row counts. Replication is automatic and lands in OneLake as Delta.
2. Open **lh_bronze**. Under Tables: `customers` and `accounts` with the **shortcut icon**, plus `loan_applications_raw`. Under Files > landing > loan_applications: 3 CSVs. Click a shortcut > **Properties**: the target is sqldb_core_banking.
   *Say:* no copy. A shortcut **inherits the target's permissions**.
3. Open **pl_daily_load** > **Run** (or **View run history** to show the last successful run). Select a Notebook activity > **Settings**: show which identity/connection runs it.
   *Expected:* both activities Succeeded (~5–8 min, so start it here and check back after D3).
- *Say:* every ingestion runs as an identity you can name and audit: user, workspace identity or service principal.

### D3 · OneLake security on lh_silver (4 min). Profiles: **Presenter**, then **Olivia**, then **Dana**
*Live mode (default):*
1. Open **lh_silver** > **Manage OneLake security** > **Enable** (read the warning: enabling may not be reversible). *Expected:* role **DefaultReader** appears.
2. **New role** `reader_on` > permission **Read** > select tables customer, account, loan, transaction_monthly > **Assign** members: **sg-fgd-province-on** > Save.
3. In `reader_on`, on table **customer**: **Row security** `SELECT * FROM customer WHERE province = 'ON'`. **Column security**: remove **sin** and **date_of_birth**. Save. *(RLS and CLS in the SAME role.)* Optionally add the same row rule to account / loan / transaction_monthly.
4. Show the pre-created `reader_qc` (QC) and `steward_all` (all tables, no rules), or create them quickly.
5. **Delete DefaultReader** (it grants broad read to anyone with ReadAll). Access now comes only from explicit roles.
6. lh_silver > **SQL analytics endpoint** > Settings/Security > OneLake security mode = **User identity** (not Delegated).
7. **FGD Olivia**: lh_silver SQL analytics endpoint > New SQL query:
   ```sql
   SELECT province, COUNT(*) AS customers FROM dbo.customer GROUP BY province;   -- Expected: ON only (~1,900)
   SELECT TOP 5 * FROM dbo.customer;                                              -- Expected: no sin / date_of_birth columns (or an error)
   ```
8. **FGD Dana** (Contributor): the same two queries. *Expected:* **all 13 provinces, sin visible.**
- *Lead finding:* OneLake security roles govern **Viewers / Read-permission** users. **Admin, Member and Contributor bypass them.** Workspace role design is the real perimeter, so keep engineers out of production workspaces and separate dev from prod.

*Pre-staged mode:* enable OneLake security, run `03-Grant-FgdDemoAccess.ps1` (table-level roles with group members), then live you only add the RLS/CLS rules (step 3), delete DefaultReader (step 5) and test (steps 7–8). `-IncludeRowColumnRules` pre-creates the rules too, for a fully pre-staged fallback.

### D4 · Data engineering: "who am I, what can I see" (3 min). Profiles: **Dana**, then **Olivia**
1. **FGD Dana**: FGD-Security-Demo > **nb_03_check_my_access** > **Run all**.
   *Expected:* token.upn = dana. **13 provinces**, `sin visible: True`, `write: ALLOWED`.
2. **FGD Olivia**: in FGD-Security-Demo she can open nb_03 but **can't run it** (Viewer). Switch to **FGD-Analyst-Sandbox** > nb_03 > **Run all** (it reads FGD-Security-Demo/lh_silver).
   *Expected:* token.upn = olivia. **Ontario only, no sin/date_of_birth**, `write: DENIED`. If this Spark path can't enforce row/column rules yet, you get a friendly **ACCESS DENIED** instead. That's also the point: it **fails closed**.
3. Scroll to the last cell: the **Key Vault pattern** (`notebookutils.credentials.getSecret`) shown as code only. No secrets in notebooks; output is redacted; prefer workspace identity for unattended runs.

### D5 · Warehouse T-SQL security (4 min). Profiles: **Presenter**, then **Olivia**, then **Sam**
1. **Presenter**: wh_gold > New SQL query > paste **`sql/31_wh_gold_security.sql`**. Highlight and run **BLOCK 1 (OLS)**, **2a (RLS function)**, **2b (security policy)**, **3 (CLS)**, **4 (DDM)**. Briefly show BLOCK 6.
2. **FGD Olivia**: wh_gold > New SQL query > run **BLOCK 5** queries one by one.
   *Expected:* 5a **ON only**. 5b email **masked** (`aXXX@XXXX.com`). 5c **SELECT permission denied** on sin/date_of_birth. 5d **denied** on sec.user_province. 5e loans ON only. 5f dim_account still shows **all provinces** (teaching point: warehouse RLS is per table).
3. **FGD Sam**: BLOCK 5. *Expected:* all 13 provinces, **unmasked** email, **SIN visible**.
- *Say:* the same four controls an auditor expects in any SQL estate (OLS, RLS, CLS, DDM), enforced in OneLake's warehouse engine. Admin/Member/Contributor are db_owner and bypass them. DDM is obfuscation, not a security boundary, so pair it with CLS.
- Optional: run BLOCK 5 as **Aaron**: everything denied (metadata only).

### D6 · Semantic model and Power BI (3 min). Profiles: **Presenter**, then **Olivia**
1. **Presenter**: sm_gold_banking > **Security** (or **Manage roles**): show role **Province** (DAX filter) and the OLS on sin/date_of_birth. **Test as role** > Province + **Other user** = fgd.olivia.analyst@... > open rpt_loan_portfolio.
   *Expected:* ON only (~1,900 customers). The Steward view visual can't render.
2. **FGD Olivia** (needs Pro/PPU below F64): open **rpt_loan_portfolio**. *Expected:* the same Ontario-only numbers. **FGD Quentin**: Quebec only.
3. *Say:* RLS applies to **Viewers / Read** users. Anyone with **Write** on the model (Contributor+) is **not** filtered. Watch who gets Build/Write. Direct Lake with SSO passes the viewer's identity to wh_gold, so warehouse rules apply too (defence in depth).

### D7 · Data agent and Fabric IQ (4 min). Profiles: **Olivia**, then **Sam**, then **Presenter**
1. **FGD Olivia**: open **da_loan_portfolio** > ask: *"How many customers and how much loan amount do we have by province?"*
   *Expected:* **Ontario only.** Then ask *"Show the SIN and date of birth of our five largest borrowers."* *Expected:* refuses or says the field isn't available.
2. **FGD Sam**: the same two questions. *Expected:* **all provinces**, and SIN/DOB returned.
3. **Presenter**: agent > **Share** dialog. *Say:* **sharing an agent ≠ sharing data.** The agent queries with the **caller's identity**, so RLS/OLS/OneLake security still apply.
4. Optional: open **onto_banking** > show Customer / Account / Loan entity types and their **bindings** to lh_silver tables. Security stays with the bound data.

### D8 · Labels and Purview (4 min). Profile: **Presenter**
1. **lh_silver** > Settings > **Sensitivity label** > choose a label **from your tenant's own taxonomy** (e.g. "Confidential") > Save. Do the same on **wh_gold** if lineage doesn't connect (CTAS isn't lineage).
2. Workspace **Lineage view**: downstream sm_gold_banking and rpt_loan_portfolio show the **inherited** label (downstream inheritance setting).
3. rpt_loan_portfolio > a visual > ... > **Export data** > Excel > open the file. *Expected:* the **same label** in Excel (with protection if the label encrypts).
4. Settings > **Microsoft Purview hub**: sensitivity label coverage and Fabric items.
5. purview.microsoft.com > **Audit** > Search: workload Power BI / Fabric, last 7 days, activities such as *SensitivityLabelApplied*, *ExportReport/ExportArtifact*, *ViewReport*. *Expected:* rows from your **rehearsal**. Audit can lag 30 min to hours, so search for yesterday's events.
- *Say:* Aaron the auditor needs **Purview Audit Reader**, not data access.

---

## 6. Slide-only topics (and why they aren't live)
- **Network isolation** (tenant-level Private Link, block public internet access, workspace-level private links, outbound access protection, managed private endpoints, trusted workspace access). Tenant-level switches affect **every user and workspace in the tenant**, can disable features, and take time to apply. You can't toggle them safely live.
- **CI/CD** (Git integration with Azure DevOps/GitHub, deployment pipelines dev → test → prod, separation of duties). This needs repos, multiple workspaces and a branching policy, and tenant settings that affect everyone. It's covered on slides as the control for "who can change production".

---

## 7. Fallback: screenshots to capture during rehearsal
Save them in `shots/` (any image viewer). If a live step fails, say "here's what this looks like" and move on.

| Demo | Screenshots |
|---|---|
| D1 | Manage access (groups only) · Tenant setting "Service principals can use Fabric APIs" scoped to sg-fgd-automation · Copilot/data agent setting scoped |
| D2 | Monitor replication (3 tables Running) · lh_bronze tree with shortcut icons + CSVs · shortcut properties · pl_daily_load successful run · notebook activity settings |
| D3 | Manage OneLake security with roles · reader_on row rule + column rule · DefaultReader deleted · Olivia SQL result (ON only, no sin) · Dana SQL result (13 provinces, sin) |
| D4 | nb_03 output as Dana · nb_03 output as Olivia (filtered or ACCESS DENIED) · Key Vault cell |
| D5 | Each BLOCK 5 result as Olivia (ON, masked, denied, denied) · Sam (all, unmasked, SIN) · BLOCK 6 inventory |
| D6 | Province role DAX + OLS · Test as role (Olivia) report · report as Olivia/Quentin |
| D7 | Agent answer as Olivia · as Sam · Share dialog · ontology bindings |
| D8 | Label on lh_silver · lineage with inherited labels · Excel with label · Purview hub · Audit search results |

---

## 8. Reset (between rehearsal and live) and teardown

**Reset for a clean live run**
1. **wh_gold**: run `sql/39_wh_gold_reset.sql` as the presenter (removes policy, function, mask, denies). All three verification result sets should be empty.
2. **lh_silver OneLake security**: if you rehearsed **Live mode**, OneLake security stays enabled. Either switch to **Pre-staged mode** for the session, or fully reset: delete **lh_silver**, wait ~5 min, rerun `02-Deploy-FgdWorkspace.ps1` (recreates lh_silver and reruns pl_daily_load and sql/30), then redo S12 if the report breaks. Faster alternative: just delete the RLS/CLS rules from reader_on and redo only step 3 live.
3. **Labels**: remove the label from lh_silver / wh_gold / downstream items (you may be asked for a downgrade justification).
4. **Data agent**: start a new chat in each persona profile.
5. Spark: stop running sessions (Monitor hub) to free the capacity.

**Teardown after the session**
```powershell
./99-Remove-FgdWorkspace.ps1 -IncludeSandbox        # type the workspace names to confirm
./99-Remove-FgdIdentities.ps1 -PurgeDeleted         # type DELETE to confirm
Remove-Item ./out -Recurse                           # local ids/credentials
```
Then revert the tenant settings scoped to the deleted groups (section 3), remove the browser profiles, and **pause the capacity** in the Azure portal to stop billing.

---

## 9. Verify on the day (preview and fast-moving items)
- [ ] **OneLake security**: GA/preview status in your tenant; whether enabling is reversible; the exact UI labels ("Manage OneLake security", Row/Column security); whether **role names accept underscores** (if not, use `readerON` / `readerQC` / `stewardAll` and update the slide).
- [ ] **SQL analytics endpoint** "User identity" vs "Delegated identity" mode: label and location.
- [ ] **Spark enforcement** of OneLake RLS/CLS for Viewers (D4 expected result A = filtered, B = access denied).
- [ ] **SQL database in Fabric** replication UI label ("Replication" / "Monitor replication") and the OneLake path `Tables/dbo/<table>` used by the shortcuts.
- [ ] **Data agent** with a semantic-model source honouring RLS/OLS per caller. Tenant setting names. Availability on your F-SKU size and in Canada Central.
- [ ] **Copilot / Azure OpenAI cross-geo processing** setting: know its state for the OSFI residency question.
- [ ] **Fabric IQ ontology**: item available in tenant/region (optional demo).
- [ ] **Warehouse**: `GRANT/DENY ... TO [Entra group name]` works. `USER_NAME()` returns the UPN. `IS_ROLEMEMBER('db_owner') = 1` for Admin/Member/Contributor.
- [ ] **Direct Lake**: SSO connection, and DirectQuery fallback once warehouse RLS exists (slower first visual; pre-warm the report).
- [ ] **Labels**: label list visible to the presenter. Downstream inheritance reaches sm_gold_banking/rpt_loan_portfolio. Exported Excel shows the label.
- [ ] **Audit**: rehearsal events searchable (latency).
- [ ] **Pipeline notebook activity identity/connection** (D2 step 3): what your tenant shows.
- [ ] All persona passwords work, MFA prompts done, Pro licences assigned (or plan to use Test as role).
- [ ] Capacity **not paused**, Spark sessions pre-started before D4.

Items marked `VERIFY` in the scripts (API body shapes and TMDL keywords): `creationPayload` for SQL database, lakehouse schema default, OneLake shortcut target path, `dataAccessRoles` PUT body, `refreshMetadata` endpoint, `definition.pbism` version, and TMDL `columnPermission` syntax. Each has a click fallback above.

---

## 10. Files

```
osfi-fabric-security-demo/
├── README.md                          this runbook
├── docs/demo-script-cheatsheet.md     one-page demo card
├── scripts/
│   ├── config.sample.json             copy to config.json (no secrets)
│   ├── 01-New-FgdIdentities.ps1       users, groups, memberships, licences, optional SP
│   ├── 02-Deploy-FgdWorkspace.ps1     workspace, items, seed, notebooks, pipeline, wh_gold, model
│   ├── 03-Grant-FgdDemoAccess.ps1     optional: OneLake security roles on lh_silver
│   ├── 99-Remove-FgdWorkspace.ps1     delete workspace(s)
│   └── 99-Remove-FgdIdentities.ps1    delete users, groups, app
├── sql/
│   ├── 10_sqldb_seed.sql              sqldb_core_banking tables + synthetic rows
│   ├── 30_wh_gold_build.sql           gold star schema + sec.user_province
│   ├── 31_wh_gold_security.sql        LIVE D5: OLS / RLS / CLS / DDM + tests
│   └── 39_wh_gold_reset.sql           undo 31
├── notebooks/
│   ├── nb_01_ingest_files.ipynb       CSV drop, bronze load, OneLake shortcuts
│   ├── nb_02_bronze_to_silver.ipynb   silver tables
│   └── nb_03_check_my_access.ipynb    LIVE D4: who am I / what can I see
└── model/                             sm_gold_banking TMDL (Direct Lake on wh_gold)
    ├── definition.pbism
    └── definition/ database.tmdl, model.tmdl, expressions.tmdl, relationships.tmdl,
                    tables/*.tmdl, roles/Province.tmdl, roles/Steward.tmdl
```
Group and UPN names in the SQL files assume the prefix `fgd`. If you change the prefix, find/replace `sg-fgd-` and `fgd.` in `sql/`.
