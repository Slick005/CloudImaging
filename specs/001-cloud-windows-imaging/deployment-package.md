# Cloud Imaging: Deployment Package

**Version**: See release tag  
**Spec reference**: FR-041, FR-044a, T107

---

## Package Contents

| File / Folder | Description |
|---|---|
| `DeviceGatewayApi.zip` | Azure Functions isolated-worker .NET 10 package |
| `OperatorApi.zip` | Azure Functions isolated-worker .NET 10 package |
| `ImagingCoreApi.zip` | Azure Functions isolated-worker .NET 10 package |
| `portal-backend.zip` | Node 22 / Express 5 App Service package, including production `node_modules` |
| `portal-frontend.zip` | React 19 + Vite Static Web App output |
| `cloud-imaging-client-v<version>.zip` | WinPE-runnable WPF executable (net10.0-windows, win-x64 self-contained) |
| `cloud-imaging-mediabuilder-v<version>.zip` | Technician workstation WPF app (net10.0-windows, win-x64 self-contained) |
| `install.ps1` | Installs the component packages into a newly provisioned environment |
| `upgrade.ps1` | Upgrades an existing deployment to the release this bundle contains |
| `post-install.ps1` | Grants the Microsoft Graph permission and Operator API role to the managed identities |
| `version.txt` | Release version this bundle was built from |
| `bicep/main.json` | Compiled root ARM template, published as the Template Spec |
| `bicep/` | Bicep sources and modules, for reference and local builds |
| `uiFormDefinition.json` | Azure Template Spec portal wizard UI definition |
| `parameters/dev.parameters.json` | Dev-environment parameter template |
| `parameters/test.parameters.json` | Test-environment parameter template |
| `parameters/prod.parameters.json` | Production parameter template |
| `scripts/publish-template-spec.ps1` | Publishes the compiled template + uiFormDefinition as an Azure Template Spec |
| `scripts/new-app-registrations.ps1` | Creates (or repairs) the three Entra app registrations, their enterprise applications and the Media Builder admin consent |
| `scripts/verify-app-registrations.ps1` | Checks the Entra app registrations against what the deployment expects |
| `SHA256SUMS` | SHA-256 checksums for all ZIP artifacts |

The bundle is flat: `install.ps1`, `upgrade.ps1` and `post-install.ps1` sit at its root, next to
the component packages they deploy. Nothing is downloaded at run time, so the bundle you extract
fully determines the version that gets installed.

---

## Prerequisites

| Requirement | Version / Notes |
|---|---|
| Azure subscription | Owner, or Contributor + User Access Administrator, on the target resource group |
| Az PowerShell module | `Az.Accounts`, `Az.Resources`, `Az.Storage`, `Az.Websites`, `Az.ManagedServiceIdentity` |
| Microsoft Graph PowerShell | `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`, used by `post-install.ps1` |
| Azure Static Web Apps CLI | `npm install -g @azure/static-web-apps-cli`, the only non-Az dependency |
| Entra ID tenant | Permissions to create/modify App Registrations |

Azure CLI is not required. The compiled `bicep/main.json` ships in the bundle, so the Bicep CLI is
not required either.

---

## First-Time Deployment (Fresh Tenant)

### 1. Publish the Template Spec

```powershell
.\scripts\publish-template-spec.ps1 -ResourceGroupName rg-cloudimaging-prod -Location eastus
```

The version is read from the bundle's `version.txt`. The script outputs a portal URL: open it to
launch the wizard.

### 2. Fill in the Wizard

| Tab | Field | Value |
|---|---|---|
| Basics | Subscription | Your subscription |
| Basics | Resource group | Create or select |
| Configuration | Resource prefix | `mse` (1-12 lowercase letters, digits or hyphens) |
| Configuration | Environment | `prod` |
| Configuration | User Auth Client ID | App Registration A Client ID |
| Configuration | Operator API Client ID | App Registration B Client ID |
| Configuration | Directory (Tenant) ID | Auto-populated |
| Configuration | Azure region | e.g. `eastus` |
| Configuration | Deployment tier | Standard (WAF_v2 = Enterprise) |

Click **Review + Create** then **Create**.

### 3. Install the Application Code

The wizard provisions empty resources. Install the component packages into them:

```powershell
.\install.ps1 -ResourceGroupName rg-cloudimaging-prod -SubscriptionId <subscription-id>
```

### 4. Complete the Entra Grants

Run once after the code is installed:

```powershell
.\post-install.ps1 -ResourceGroupName rg-cloudimaging-prod -SubscriptionId <subscription-id> -OperatorApiClientId <client-id>
```

This grants `DeviceManagementServiceConfig.Read.All` to the Imaging Core managed identity and
`CloudImaging.PortalAccess` to the portal backend managed identity. Both grants are idempotent.

---

## Upgrade (Existing Deployment)

Extract the newer release bundle and run the `upgrade.ps1` inside it:

```powershell
.\upgrade.ps1 -ResourceGroupName rg-cloudimaging-prod -SubscriptionId <subscription-id>
```

The script:
1. Discovers deployed Function Apps, App Service and Static Web App by naming convention
2. Uploads each component package to the deployment's own storage account and repoints the app at it
3. Re-applies the boot image storage CORS rule, which a code-only upgrade would otherwise miss
4. Does **not** re-provision infrastructure and does **not** download anything

---

## Component Architecture

```
Internet
    │
    ▼
[Device Gateway API]  ← WinPE Cloud Imaging Client (mTLS)
    │ Private Link
    ▼
[Imaging Core API]  ← internal-only, no public endpoint
    │
    ├─ Table Storage (session state, images, boot images, branding)
    ├─ Blob Storage (OS image blobs, boot WIMs, branding logo)
    └─ Azure Key Vault (boot media certificate PFX)

[Operator API]  ← Portal backend (Entra-authenticated)
    │ Private Link
    └── Imaging Core API

[Portal Backend]  ← App Service, Entra ID B2C/MT
[Portal Frontend] ← Azure Static Web Apps

[Cloud Imaging Client]   → Device Gateway API (mTLS)
[Cloud Imaging Media Builder] → Operator API (Entra)
```

---

## Naming Convention

| Resource type | Pattern | Example |
|---|---|---|
| Function Apps | `{prefix}-{env}-ci-func-{name}` | `mse-prod-ci-func-gateway` |
| App Service | `{prefix}-{env}-ci-app-portal` | `mse-prod-ci-app-portal` |
| Static Web App | `{prefix}-{env}-ci-stapp-portal` | `mse-prod-ci-stapp-portal` |
| Storage Account | `{prefix}{env}ci{purpose}` | `mseprodcistapp` |
| Key Vault | `{prefix}-{env}-ci-kv` | `mse-prod-ci-kv` |
| VNet | `{prefix}-{env}-ci-vnet` | `mse-prod-ci-vnet` |
| Log Analytics | `{prefix}-{env}-ci-law` | `mse-prod-ci-law` |

Storage account names strip the hyphens, because the resource type does not allow them.
`install.ps1` and `upgrade.ps1` anchor on the `*-ci-func-gateway` Function App and derive every
other name from it, so nothing has to be passed in.

---

## Checksums

Verify download integrity:

```powershell
Get-FileHash cloud-imaging-v1.0.0.zip -Algorithm SHA256
# Compare against SHA256SUMS
```

---

*For troubleshooting, see `docs/operations-runbook.md`. For quick start, see `docs/setup-instructions.md`.*
