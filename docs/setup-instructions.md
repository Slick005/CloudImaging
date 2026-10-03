# Cloud Imaging Setup Instructions

**Audience**: IT administrators deploying Cloud Imaging into their own Azure tenant

This is the guide to follow for a full deployment, start to finish. It's organized into five
phases, run in order. Step numbers restart within each phase, so a cross-reference to another
phase names both ("Phase 3, Step 2").

| Phase | Covers | Steps |
|---|---|---|
| [1. Prerequisites](#phase-1-prerequisites) | Install tooling, download the deployment scripts, create the three Entra ID app registrations | 1 step |
| [2. Deploy the Azure resources](#phase-2-deploy-the-azure-resources) | Publish the Template Spec, run the deployment wizard, update the portal redirect URI, deploy the application code | 4 steps |
| [3. Post-deployment setup](#phase-3-post-deployment-setup) | Run the post-deploy script, assign user roles, complete the initial portal configuration (boot media certificate, OS images, optional settings) | 3 steps |
| [4. Configure the Media Builder](#phase-4-configure-the-media-builder) | Point the desktop app at your tenant, install the Windows ADK, deploy the MSI with Intune | 1 step |
| [5. Operate Cloud Imaging](#phase-5-operate-cloud-imaging) | Generate a boot image, prepare USB media, image a device | 3 steps |

---

## Phase 1: Prerequisites

### What You'll Need

| Requirement | Details |
|---|---|
| Azure subscription | Contributor + User Access Administrator on target resource group, **plus** `Microsoft.AlertsManagement` registered on the subscription (see note below) |
| Az PowerShell | `Install-Module Az.Accounts, Az.ManagedServiceIdentity, Az.Resources, Az.Storage, Az.Websites -Scope CurrentUser` |
| Microsoft Graph PowerShell | `Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser` |
| Node.js | `winget install OpenJS.NodeJS.LTS`, then open a new terminal. Needed only to install the tool below |
| Azure Static Web Apps CLI | `npm install -g @azure/static-web-apps-cli`. Required: `install.ps1` publishes the portal frontend with it, and there is no PowerShell equivalent |
| Entra ID permissions | Create/update App Registrations; Privileged Role Administrator or Global Administrator for the post-deployment Microsoft Graph permission grant |
| Microsoft Intune | An active Intune license is required when device pre-flight authorization is enabled |
| Windows ADK + WinPE add-on | On every technician workstation that runs Media Builder: see [Installing the Windows ADK](#installing-the-windows-adk-on-technician-workstations) |

> **Verify the Static Web Apps CLI before you start.** Run `swa --version`. If the command is not
> found, open a new terminal.

> **Why both Contributor *and* User Access Administrator?** The Bicep package creates Azure role
> assignments for the deployed managed identities (Storage, Key Vault, package containers) as part
> of the deployment (`Microsoft.Authorization/roleAssignments` resources). Built-in
> **Contributor** explicitly excludes `Microsoft.Authorization/*/Write`, so it can't create
> those role assignments on its own; without the extra role (or **Owner**, which already
> includes it), the deployment fails partway through with an authorization error.

> **Resource provider registration.** Azure Resource Manager auto-registers a resource provider
> the first time a resource of that type is deployed into a subscription, but only for a caller
> that holds `<provider>/register/action` at the **subscription** scope; a role assigned only at
> the resource group scope (as above) doesn't carry that permission, because a provider's
> registration state belongs to the subscription, not the group. Every provider this template uses
> except one (`Microsoft.Web`, `Microsoft.Storage`, `Microsoft.Network`, `Microsoft.KeyVault`,
> `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.ManagedIdentity`,
> `Microsoft.Authorization`) comes pre-registered on virtually every subscription. The exception is
> `Microsoft.AlertsManagement` (used for Application Insights' "Failure Anomalies" alert), which is
> missing on some newly-created and sponsorship subscriptions, and its registration failing part
> way through the deployment aborts everything after it. Before Step 1, check it with an account
> that has Owner or Contributor **on the subscription itself** and register it if needed:
> ```powershell
> Get-AzResourceProvider -ProviderNamespace Microsoft.AlertsManagement | Select-Object ProviderNamespace, RegistrationState
> # If RegistrationState is anything other than "Registered":
> Register-AzResourceProvider -ProviderNamespace Microsoft.AlertsManagement
> ```
> This is a one-time, subscription-wide setting; it carries over to future upgrades into the same
> subscription.

---

### Get the Deployment Scripts

Every script this guide tells you to run ships inside the deployment bundle:
`scripts\verify-app-registrations.ps1` and `scripts\publish-template-spec.ps1`, plus
`install.ps1`, `post-install.ps1` and `upgrade.ps1` at the root. Get the bundle now so it's
ready for every phase that follows:

1. Download **`cloud-imaging-<version>.zip`** (e.g. `cloud-imaging-v1.0.0.zip`) from the
   backend/infrastructure release on the [GitHub Releases](https://github.com/MSEndpointMgr/CloudImaging/releases)
   page: the bundle without `-client-` or `-mediabuilder-` in its name, since those ship
   separately. Optionally verify it against the accompanying `SHA256SUMS` file.
2. Extract it. Everything sits in that one folder: the component packages, the three deployment
   scripts, `scripts\`, `bicep\`, `parameters\` and `uiFormDefinition.json`. Run every command in
   this guide from there.

### Step 1: Create Three App Registrations

Cloud Imaging uses three separate Entra ID App Registrations, each with a single, clear purpose:

| Registration | Client type | Purpose |
|---|---|---|
| **Cloud Imaging Portal** | Single-page application (SPA) | Browser portal sign-in (technicians & administrators) |
| **Cloud Imaging Operator API** | Web API (service-to-service) | Token audience for the Operator API |
| **Cloud Imaging Media Builder** | Mobile & desktop (public client) | Media Builder desktop app sign-in |

> **Why three?** The browser portal is a Single-Page Application and the Media Builder is a native
> public client. Entra classifies these client types differently, and mixing an SPA platform with a
> *Mobile and desktop* platform in the **same** registration causes the SPA's cross-origin token
> redemption to be rejected with **AADSTS9002326**. Keeping them in separate registrations avoids
> this entirely.

#### Option A *(recommended)*: create all three with a script

`new-app-registrations.ps1` creates the three registrations below exactly as described, along with
their enterprise applications, and grants admin consent for the Media Builder's Operator API
permission. It's part of the deployment bundle from
[Get the Deployment Scripts](#get-the-deployment-scripts); run it from the `deploy/` folder with an
account that holds **Application Administrator** or **Cloud Application Administrator**:

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser
.\scripts\new-app-registrations.ps1 -TenantId "<your-tenant>.onmicrosoft.com"
```

It ends by printing `portalClientId`, `operatorApiClientId` and `mediaBuilderClientId` for the
Template Spec wizard in [Phase 2](#phase-2-deploy-the-azure-resources), and the matching
`verify-app-registrations.ps1` command.

- **Safe to re-run.** Registrations are matched by display name. An existing one only gets what's
  missing added (and the known sign-in breakers fixed); nothing you added yourself is removed.
- **Different names:** `-DisplayNamePrefix "Contoso Imaging"` names them *Contoso Imaging Portal*
  and so on.
- **No consent rights?** Add `-SkipAdminConsent`, then have an administrator click
  **Grant admin consent** on the Media Builder registration's **API permissions** page
  (Registration 3, step 7).
- **Preview first:** `-WhatIf` shows what would be created or changed without changing anything.

The Portal starts with the `https://localhost` placeholder redirect URI. After Phase 2, re-run the
script with `-PortalRedirectUri` to complete [Phase 2, Step 3](#step-3-update-the-portal-redirect-uri).

#### Option B: create them in the Microsoft Entra admin center

Follow the three sections below.

#### Registration 1: Cloud Imaging Portal (browser SPA)

1. In Entra ID → App Registrations → **New registration**
2. Name: `Cloud Imaging Portal` (or your branding)
3. Supported account types: **Single tenant**
4. Under **Redirect URI (optional)**, select **Single-page application (SPA)** as the platform
   and enter a placeholder URI for now (e.g. `https://localhost`). You don't have a Static Web
   App hostname yet, it's only created by the deployment in
   [Phase 2](#phase-2-deploy-the-azure-resources). You replace it in
   [Phase 2, Step 3](#step-3-update-the-portal-redirect-uri) with the real hostname
   (e.g. `https://<swa-name>.azurestaticapps.net`). Do **not** pick
   *Public client/native (mobile & desktop)* here; that reclassifies the app and breaks SPA
   sign-in with **AADSTS9002326**.
5. Once created, record the **Application (client) ID** shown on the **Overview** page → this
   is `portalClientId`. You'll need it in a couple of the steps below.
6. Under **Authentication** → **Advanced settings**, leave **Allow public client flows** = **No**. Setting it to **Yes** breaks the browser portal: the SPA's cross-origin token redemption is then rejected with **AADSTS9002326** (*cross-origin token redemption is permitted only for the 'Single-Page Application' client-type*).
7. Under **Expose an API**:
   - Set the **Application ID URI** to `api://<portalClientId>` (accept the default; Entra
     pre-fills this with the `portalClientId` you already recorded above).
   - Click **Add a scope** and fill in the form:
     - **Scope name**: `user_impersonation`
     - **Who can consent?**: Admins and users
     - **Admin consent display name**: `Access Cloud Imaging Portal backend`
     - **Admin consent description**: `Allows the app to access the Cloud Imaging Portal backend on behalf of the signed-in user.`
     - Leave **User consent display name** and **User consent description** blank; Entra falls back to the admin consent text above when they're empty, so there's nothing to fill in.
     - **State**: Enabled
     - Click **Add scope**.
     - The browser portal (an MSAL SPA) requests `api://<portalClientId>/user_impersonation` to obtain an access token for the portal backend; without it, sign-in fails with **AADSTS500011 (invalid_resource)** and the portal renders a blank page after sign-in.
8. Under **App roles**, add these three roles. Each needs a **Display name** (use the same text
   as the value), **Value**, **Allowed member types**, and **Description**:
   - **`CloudImaging.Administrator`**
     - Value: `CloudImaging.Administrator`
     - Allowed member types: Users/Groups
     - Description: `Full access to Cloud Imaging: catalog writes, branding, configuration, and the boot-media certificate.`
   - **`CloudImaging.Technician`**
     - Value: `CloudImaging.Technician`
     - Allowed member types: Users/Groups
     - Description: `Day-to-day imaging operations: sessions, coupling, assignment, and read-only catalogs.`
   - **`CloudImaging.Reader`**
     - Value: `CloudImaging.Reader`
     - Allowed member types: Users/Groups
     - Description: `Read-only access to the Dashboard and Reports.`
     - Read-only, limited to the Dashboard and Reports; see [roles-and-access.md](roles-and-access.md).
9. *(Optional)* Under **API permissions**, grant admin consent for the **Microsoft Graph →
   User.Read** delegated permission; Entra adds it to every new registration by default, so
   there's nothing to add, only consent to grant. It's used only to show the signed-in user's
   **profile photo** in the header (their name always displays regardless, from the sign-in
   token); without consent, the portal falls back to an initials avatar. Skipping this is
   always safe, including in tenants that block user consent to Graph permissions: the
   portal never bundles this scope with the required sign-in scope, so it can't affect
   sign-in either way.

> The portal backend calls the Operator API using its **managed identity** (the `CloudImaging.PortalAccess` app role, assigned automatically in Phase 3, Step 1). The Portal registration therefore needs **no** API permission to the Operator API.

#### Registration 2: Cloud Imaging Operator API (service-to-service)

1. New registration. Name: `Cloud Imaging Operator API`
2. Supported account types: **Single tenant**
3. Leave **Redirect URI (optional)** blank on this same page; this registration is a pure API
   resource with no interactive sign-in of its own, so it never needs a redirect URI or platform.
4. Once created, record the **Application (client) ID** shown on the **Overview** page → this
   is `operatorApiClientId`. You'll need it in the next step below.
5. Under **Expose an API**:
   - Set the **Application ID URI** to `api://<operatorApiClientId>` (accept the default;
     Entra pre-fills this with the `operatorApiClientId` you already recorded above).
   - Click **Add a scope** and fill in the form:
     - **Scope name**: `user_impersonation`
     - **Who can consent?**: Admins and users
     - **Admin consent display name**: `Access Cloud Imaging Operator API`
     - **Admin consent description**: `Allows the app to access the Cloud Imaging Operator API on behalf of the signed-in user.`
     - Leave **User consent display name** and **User consent description** blank; Entra falls back to the admin consent text above when they're empty, so there's nothing to fill in.
     - **State**: Enabled
     - Click **Add scope**.
     - This delegated scope lets the Media Builder (an interactive user-facing public client) obtain an access token for the Operator API; without it, sign-in fails with **AADSTS650057 (Invalid resource)**.
6. Under **App roles**, add these two roles. Each needs a **Display name** (use the same text
   as the value), **Value**, **Allowed member types**, and **Description**:
   - **`CloudImaging.PortalAccess`**
     - Value: `CloudImaging.PortalAccess`
     - Allowed member types: **Applications**
     - Description: `Lets the Portal backend's managed identity call the Operator API on the signed-in user's behalf.`
     - Used by the portal backend managed identity.
   - **`CloudImaging.MediaBuilderAccess`**
     - Value: `CloudImaging.MediaBuilderAccess`
     - Allowed member types: **Both (Users/Groups + Applications)**
     - Description: `Lets a signed-in technician's Media Builder client call the Operator API.`
     - Assigned to the technicians who run the Media Builder. It **must** allow *Users/Groups*, otherwise the technician's interactive token never carries the role and API calls return `403`.

#### Registration 3: Cloud Imaging Media Builder (desktop public client)

1. New registration. Name: `Cloud Imaging Media Builder`
2. Supported account types: **Single tenant**
3. Under **Redirect URI (optional)**, select **Public client/native (mobile & desktop)** as the
   platform and enter `http://localhost` as the URI. The Media Builder signs in with the
   interactive loopback (authorization code + PKCE) flow.
4. Once created, record the **Application (client) ID** shown on the **Overview** page → this
   is `mediaBuilderClientId`.
5. Under **Authentication** → **Advanced settings**, leave **Allow public client flows** = **No**; the loopback flow is already identified as a public client by its `http://localhost` redirect and does not need this flag.
6. Under **App roles**, add the same two role names, but with descriptions scoped to what they
   mean *in the Media Builder* (this is a separate app role definition from the Portal
   registration's roles above, even though the names match). Each needs a **Display name** (use
   the same text as the value), **Value**, **Allowed member types**, and **Description**:
   - **`CloudImaging.Administrator`**
     - Value: `CloudImaging.Administrator`
     - Allowed member types: Users/Groups
     - Description: `Full Media Builder access: generate boot images (embeds the active boot-media certificate and branding) and prepare USB storage devices.`
   - **`CloudImaging.Technician`**
     - Value: `CloudImaging.Technician`
     - Allowed member types: Users/Groups
     - Description: `Prepare USB storage devices with an already-published boot image. Cannot generate new boot images (Administrator-only).`
7. **Grant access to the Operator API (required):** Under **API permissions** → **Add a
   permission** → **My APIs** → select **Cloud Imaging Operator API** → **Delegated
   permissions** → check `user_impersonation` → **Add permissions**. Then click **Grant admin
   consent for &lt;your tenant&gt;**. The Media Builder requests the
   `api://<operatorApiClientId>/.default` scope, which only succeeds once this permission is
   consented; skipping it fails sign-in with **AADSTS650057**.

#### *(Optional)* Verify the three app registrations before continuing

`verify-app-registrations.ps1` re-checks the settings above via Microsoft Graph (read-only, no
changes made) and prints a pass/fail checklist, so mistakes surface now instead of as a cryptic
AADSTS error later. It's part of the deployment bundle from
[Get the Deployment Scripts](#get-the-deployment-scripts) above; run it from the `deploy/` folder:

```powershell
.\scripts\verify-app-registrations.ps1 -PortalClientId "<portalClientId>" -OperatorApiClientId "<operatorApiClientId>" -MediaBuilderClientId "<mediaBuilderClientId>"
```

A couple of things (admin consent status) can't be checked from a script and are called out at
the end as manual checks instead.

---

## Phase 2: Deploy the Azure Resources

### Step 1: Publish the Template Spec

Cloud Imaging deploys into a single resource group, which also holds the Template Spec. Name it
to suit your own environment's naming standard: the scripts never assume a particular name, and
the placeholders below are only placeholders. The same group is selected in the wizard in Step 2,
and passed to every script in this guide.

Run these from the folder you extracted in [Get the Deployment Scripts](#get-the-deployment-scripts):

```powershell
# Authenticate
Connect-AzAccount

# Substitute your own values.
$ResourceGroupName = "<your-resource-group>"
$Location = "<location>"

# Create the resource group that will hold the entire deployment.
# <location> is an Azure region short name, for example westeurope, northeurope or
# swedencentral in Europe, or eastus, eastus2 or westus2 in the United States.
New-AzResourceGroup -Name $ResourceGroupName -Location $Location

# Publish
.\scripts\publish-template-spec.ps1 -ResourceGroupName $ResourceGroupName -Location $Location
```

The Template Spec is versioned to match the release bundle automatically, so there is no version
to type.

The script publishes a **Template Spec** named `CloudImaging` into that resource group, then
prints a direct link to it in the Azure Portal (the marketplace `#create` URL doesn't work for
Template Specs, so this manual link is how you reach it). Open the link (signed in to the target
tenant) and click **Deploy** on the Template Spec resource's page; that launches the Form View
wizard used in Step 2. To navigate manually instead: **Resource groups → your resource group →
CloudImaging → Deploy**.

---

### Step 2: Deploy via Template Spec Wizard

Fill in the wizard. It has two tabs:

**Basics**

- **Subscription / Resource group / Region**:
  - Select the **same resource group you created in Step 1**, so the deployment and the Template
    Spec live together.
  - Pick the region closest to your users.
  - Your Entra tenant ID is taken from this subscription automatically, so there's nothing to
    enter for it.
- **Deployment Environment**: `Production (prod)` (or `Development (dev)` for testing). This
  becomes the second segment of every resource name.

**Configuration**

- **Resource Prefix**:
  - 1 to 12 lowercase letters, digits or hyphens, starting and ending with a letter or digit
    (e.g. `corp` or `corp-eu`).
  - The wizard shows a live preview of the resulting resource names beneath the field.
  - Hyphens are removed from storage account names, which cannot contain them.
- **Static Web App Region**:
  - Azure Static Web Apps is a non-regional, globally-distributed service available in only a
    handful of regions (Central US, East US 2, West US 2, West Europe, East Asia), independent
    of the region you picked in Basics for the rest of the solution.
  - Pick whichever of these is closest to your users. Content is served globally regardless of
    this choice.
- **Cloud Imaging Portal - Application (client) ID**:
  - From Registration 1 (`portalClientId`), the app users sign in to when they open the portal.
- **Operator API - Application (client) ID**:
  - From Registration 2 (`operatorApiClientId`), the API the portal and operator clients call on
    the operator's behalf.
- **Cloud Imaging Media Builder - Application (client) ID**:
  - From Registration 3 (`mediaBuilderClientId`), the app the Media Builder desktop tool
    authenticates as when it calls the Operator API on the signed-in technician's behalf.
- **Deployment Tier**:
  - `Standard` enforces mTLS at the Function App layer and is the right choice for most
    organizations.
  - `Enterprise` additionally puts an Application Gateway WAF_v2 in front of the Device Gateway
    API.
- **Compute**, **Security Settings**, and **Networking**: every field here is pre-filled with a
  working default. Only change them if you have specific sizing, certificate/token lifetime, or
  IP addressing requirements.

Click **Create** and wait ~15 minutes.

> **If the deployment fails with "No available instances to satisfy this request"** (error code
> `03029`, usually on one of the `*-plan-*` App Service plans), the Azure scale unit behind your
> resource group has run out of Elastic Premium capacity. Nothing is wrong with your input. The
> deployment creates three Elastic Premium plans at once, one per Function App, because each
> needs its own delegated subnet, and they all land on the same scale unit.
>
> 1. Select **Redeploy** and run it again with the same values. Capacity often frees up within
>    minutes and the deployment is safe to repeat.
> 2. If it fails again, delete the resource group and deploy into a **new** one. Azure binds the
>    App Service capacity pool to the resource group, so a new group is usually placed on a scale
>    unit that has room.
> 3. If that still fails, choose a different region.
>
> Ignore the error's suggestion to enable Async Scaling. That applies to an existing plan, not to
> one being created.

---

### Step 3: Update the Portal Redirect URI

The deployment has now created the real portal hostname, so replace the placeholder redirect URI
from Phase 1 with it. **Portal sign-in fails with AADSTS50011 (redirect URI mismatch) until this
is done.**

If you created the registrations with `new-app-registrations.ps1`, re-run it with the Static Web
App's URL (shown on its **Overview** page). It adds that URL and removes the placeholder:

```powershell
.\scripts\new-app-registrations.ps1 -TenantId "<your-tenant>.onmicrosoft.com" -PortalRedirectUri "https://<swa-name>.azurestaticapps.net"
```

Otherwise, update it by hand:

1. Open the deployed resource group and select the **Static Web App** resource.
2. Copy its **URL** from the Overview page, for example `https://<swa-name>.azurestaticapps.net`.
3. Go to **Microsoft Entra ID** → **App registrations** → **Cloud Imaging Portal** →
   **Authentication**.
4. Under **Single-page application**, replace the placeholder redirect URI you added in
   [Phase 1, Step 1](#registration-1-cloud-imaging-portal-browser-spa) with that URL, then
   **Save**.

> **That's the only redirect URI this app needs.** The portal website and its backend are
> served from that same Static Web App address, so there's no separate backend URL to
> register anywhere.

---

### Step 4: Deploy the Application Code

The wizard creates the Azure resources, but they start out **empty**: the Template Spec does not
carry the application packages. `install.ps1` installs them. It sits in the root of the bundle
you extracted in [Get the Deployment Scripts](#get-the-deployment-scripts), next to the component
packages it deploys.

```powershell
$SubscriptionId = "<your-subscription-id>"

.\install.ps1 -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId
```

The subscription is required from here on so a deployment can never run against the wrong one.
Every resource name is worked out from the prefix and environment you chose in the wizard, so
there is nothing else to supply.

The script uploads each Function App package to the deployment's own storage account and points
the apps at it, zip-deploys the portal backend, and publishes the portal frontend with the Static
Web Apps CLI. It then verifies each component and prints a summary. It is safe to rerun.

When every row reports `Success`, open the portal URL it prints: the site should load and prompt
for sign-in. Nothing in Phase 3 works until this step succeeds.

---

## Phase 3: Post-Deployment Setup

### Step 1: Complete the Microsoft Entra Grants

Two directory-level grants remain that neither Bicep nor the Azure portal can make. `post-install.ps1`
performs both:

```powershell
.\post-install.ps1 -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId -OperatorApiClientId "<operatorApiClientId>"
```

Unlike `install.ps1`, this needs **Microsoft Entra** privileges rather than Azure ones: sign-in
asks for consent to `AppRoleAssignment.ReadWrite.All` and `Application.Read.All`, which a
Privileged Role Administrator or Global Administrator holds. If that is a different person, they
can run this step on their own machine.

The two grants are:

1. **`DeviceManagementServiceConfig.Read.All`** on Microsoft Graph, to the Imaging Core API's
   managed identity, which the device pre-flight authorization check needs to read Windows
   Autopilot and Intune corporate identifiers.
2. **`CloudImaging.PortalAccess`** on the Operator API app registration, to the portal backend's
   managed identity, so the portal backend can call the Operator API. The portal's "Users and
   groups" picker only lists users and groups, never managed identities, which is why this cannot
   be done in the UI.

Both are idempotent and verified, so the script is safe to rerun. Microsoft Entra takes time to
replicate permission changes; wait several minutes before testing pre-flight authorization.

The **user-level** roles below, including `CloudImaging.MediaBuilderAccess`, still need to be
assigned manually in Step 2.

---

### Step 2: Assign Access to Your Administrators and Technicians

The app roles created in Phase 1, Step 1 are just definitions; nobody can sign in successfully until
they're assigned to actual users or groups. For the full access model (what each role grants in the
Portal vs. the Media Builder), see [roles-and-access.md](roles-and-access.md).

Cloud Imaging spans **three** enterprise applications, and a single person needs assignments on more
than one of them. Assigning roles per user across three applications is where most access problems
start, so create one group per persona first and assign the groups instead.

#### 1. Create a group per persona

Entra ID → **Groups** → **New group** (type: Security, membership: Assigned). Create two:

- **Cloud Imaging Administrators**
- **Cloud Imaging Technicians**

Add a third, **Cloud Imaging Readers**, only if you want people who can view the Dashboard and
Reports but change nothing. Readers exist in the Portal only.

Put your people in the groups now. From here on, onboarding somebody is a single group membership
change rather than five separate role assignments.

#### 2. Assign the groups to every applicable enterprise application

For each row below: Entra ID → **Enterprise applications** → select the application →
**Users and groups** → **Add user/group** → pick the group → choose the role → **Assign**.

| Enterprise application | Cloud Imaging Administrators | Cloud Imaging Technicians | Cloud Imaging Readers |
|---|---|---|---|
| **Cloud Imaging Portal** | `CloudImaging.Administrator` | `CloudImaging.Technician` | `CloudImaging.Reader` |
| **Cloud Imaging Media Builder** | `CloudImaging.Administrator` | `CloudImaging.Technician` | not applicable |
| **Cloud Imaging Operator API** | `CloudImaging.MediaBuilderAccess` | `CloudImaging.MediaBuilderAccess` | not applicable |

That is **five** assignments in total, across three applications.

Points worth understanding before you skip a row:

- **Portal and Media Builder assignments are not shared.** They are separate app registrations, so
  granting Administrator on the Portal grants nothing on the Media Builder. Skip the Media Builder
  row and your administrators can sign in to it but reach no workflow.
- **The Operator API row is a different kind of permission.** The Portal and Media Builder roles
  decide what each app *shows* a person. `CloudImaging.MediaBuilderAccess` is what lets the Media
  Builder *call the Operator API at all*. Skip this row and sign-in still succeeds, but every call
  returns `403` and the Media Builder reports that access was denied.
- **Readers and Portal-only technicians** need only the Portal row. The Media Builder and Operator
  API rows apply to whoever builds boot media.
- **Do not assign `CloudImaging.PortalAccess`** to anyone here. It belongs to the portal backend's
  managed identity and is granted by `post-install.ps1` in Step 1.

#### 3. Have each person sign out and back in

App roles are stamped into the token at sign-in. Anyone already signed in keeps their old, roleless
token until they sign out and back in, so a correct assignment can still look broken until they do.

#### 4. Confirm the assignments took

Entra ID → **Enterprise applications** → select each of the three applications → **Users and
groups**, and check the group is listed with the expected role. The Operator API application should
show your two persona groups with `CloudImaging.MediaBuilderAccess`, alongside the portal's managed
identity with `CloudImaging.PortalAccess` that `post-install.ps1` created.

A user with no role assigned on a registration can still sign in, but sees an "Access denied"
screen (Portal) or has every workflow blocked (Media Builder).

---

### Step 3: Initial Portal Configuration

Before handing the portal to your technicians, sign in as **CloudImaging.Administrator** and
complete these one-time setup tasks. The first two are **required**; imaging cannot happen
without them; the rest are optional and can be revisited any time from **Configuration**.

1. **Generate the boot media certificate** (required).
   - Navigate to **Configuration** → **Certificates** tab → click **Generate Certificate** and
     wait for confirmation.
   - This certificate secures the mTLS handshake between booted devices and the Device Gateway
     API, and is embedded into every boot image Media Builder generates.
   - Without an active certificate, **Generate Boot Image** (Phase 4) refuses to run.
2. **Add at least one OS image to the catalog** (required).
   - Navigate to **OS Images** → **Upload** and provide the WIM/ESD file, a name, and a version.
   - Devices have nothing to image without at least one catalog entry.
3. **Configure branding** *(optional)*.
   - Navigate to **Branding** to set your organization's logo and colors.
   - Applies to both the portal and the boot media UI.
4. **Add locations** *(optional)*.
   - Navigate to **Locations** to define site labels technicians can tag onto boot media and
     filter devices by.
   - See [roles-and-access.md](roles-and-access.md) for how locations interact with access.
5. **Configure device pre-flight authorization** *(optional, off by default)*.
   - Before enabling it, confirm the Microsoft Graph permission script above ended with `[OK]`.
   - Add at least one test device to Windows Autopilot, or add its exact manufacturer, model, and
     serial-number tuple under **Intune → Devices → Enrollment → Corporate device identifiers**.
   - Under **Configuration** → **Preflight**, enable the requirement, then boot that device and
     verify its session reaches `SessionAllowed`.
   - Test an unknown device too, and verify that it reaches `SessionNotAuthorized`.
   - Disable the setting again if either result is unexpected. When disabled, registration skips
     Microsoft Graph and proceeds.
6. **Review Security and Miscellaneous settings** *(optional)*.
   - **Configuration** → **Security**: certificate/token validity periods and clock skew tolerance.
   - **Configuration** → **Miscellaneous**: session history retention.
   - Both have working defaults and only need attention for organization-specific requirements.
7. **Turn on version checking** *(optional)*.
   - **Configuration** → **Miscellaneous** → **Version** shows the release this deployment is
     running.
   - Enabling **Check GitHub for new releases** lets the portal backend periodically read the
     latest published release number from github.com and notify administrators when an upgrade is
     available.
   - It is **off by default**: it is the only outbound call the portal makes outside your tenant,
     so leave it off if your network policy prohibits that, or if the deployment has no outbound
     internet access.
   - Nothing is ever installed automatically; see
     [upgrade-instructions.md](upgrade-instructions.md).

---

## Phase 4: Configure the Media Builder

### Step 1: Configure and Distribute the Media Builder

The Media Builder is a desktop app that technicians run on their own workstations. Each
installation has to be told which tenant, sign-in app and Operator API to use, so collect these
four values first:

| # | Value | Where it comes from |
|---|---|---|
| 1 | Media Builder client ID | [Phase 1, Registration 3](#registration-3-cloud-imaging-media-builder-desktop-public-client) → Application (client) ID |
| 2 | Tenant ID | Entra ID → Overview → Directory (tenant) ID |
| 3 | Operator API client ID | [Phase 1, Registration 2](#registration-2-cloud-imaging-operator-api-service-to-service) → Application (client) ID |
| 4 | Operator API URL | The `operatorApiUrl` deployment output from [Phase 2, Step 2](#step-2-deploy-via-template-spec-wizard) |

All four are public identifiers, not secrets. The Media Builder is an MSAL *public client* and has
no client secret. Never put certificates, client secrets or connection strings in its configuration.

Supply them either on the **MSI command line** (managed deployment, recommended) or in
**`appsettings.json`** (manual install). Both are covered below.

#### Building the msiexec command line

One property per value, in the same order, all on a single line (as Intune requires):

```
msiexec /i cloud-imaging-mediabuilder-<version>.msi /qn /norestart ENTRAIDCLIENTID=<1. media builder client ID> ENTRAIDTENANTID=<2. tenant ID> OPERATORAPICLIENTID=<3. operator API client ID> OPERATORAPIBASEURL=<4. operator API URL>
```

Filled in:

```
msiexec /i cloud-imaging-mediabuilder-v1.0.0.msi /qn /norestart ENTRAIDCLIENTID=6f1c2a84-3d5b-4e17-9a2c-0b7e5d81f430 ENTRAIDTENANTID=b3e7d902-14af-4c68-85d1-7f2a6c093e55 OPERATORAPICLIENTID=d84a5f61-27c9-4b03-9e8f-1a6d3c70b214 OPERATORAPIBASEURL=https://ci-operator-api-prod.azurewebsites.net
```

Rules when assembling it:

- Property names are **uppercase**, with **no spaces** around `=`.
- Quote any value containing a space: `INSTALLFOLDER="D:\Apps\Cloud Imaging Media Builder"`.
- Give `OPERATORAPICLIENTID` the **bare client ID**. The MSI turns it into the
  `api://<operatorApiClientId>/.default` scope; pasting a full `api://...` string there is rejected
  with an error rather than installed as a broken doubled-up scope.
- `OPERATORAPIBASEURL` is the hostname only: no `/api` suffix, no trailing slash.
- Every property is optional. Omit them all to install now and configure later; the app runs but
  the sign-in screen shows *"Entra ID sign-in is not configured"* until the values are present.

Two optional properties exist beyond the four above:

| Property | Purpose |
|---|---|
| `INSTALLFOLDER` | Install location. Defaults to `%ProgramFiles%\MSEndpointMgr\Cloud Imaging Media Builder`. |
| `OPERATORAPISCOPE` | The complete scope string, replacing what `OPERATORAPICLIENTID` would derive. Only needed if you replaced the Operator API's default `api://<operatorApiClientId>` Application ID URI with a custom one. Wins when both are supplied. |

Append `/l*v C:\Windows\Temp\mediabuilder-install.log` while troubleshooting a failed install.

The MSI writes the values to `HKLM\SOFTWARE\MSEndpointMgr\CloudImaging\MediaBuilder`. To confirm
what a workstation actually received:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\MSEndpointMgr\CloudImaging\MediaBuilder' |
  Select-Object ClientId, TenantId, OperatorApiScope, OperatorApiBaseUrl, InstallFolder
```

Those same registry values can be pushed by a Group Policy preference or an Intune remediation
script, so a client ID rotation or an Operator API URL change never requires repackaging.

#### Configuring a manual install

For an xcopy install from `cloud-imaging-mediabuilder-<version>.zip` (no MSI), put the values in
`appsettings.json` beside `CloudImaging.MediaBuilder.exe` instead:

```json
{
  "EntraId": {
    "ClientId": "<1. media builder client ID>",
    "TenantId": "<2. tenant ID>",
    "OperatorApiScope": "api://<3. operator API client ID>/.default"
  },
  "OperatorApi": {
    "BaseUrl": "<4. operator API URL>"
  }
}
```

Note that this file wants the **full scope**, not the bare client ID. Deriving it is something
only the MSI does for you.

The registry values take precedence over `appsettings.json`, value by value, so an MSI-managed
workstation ignores whatever the file contains. Leave the shipped file at its empty defaults when
you deploy the MSI.

> **Two things are needed for a working Media Builder sign-in. Don't skip either:**
> 1. The **`user_impersonation` delegated permission** on the Media Builder registration, added
>    *and* admin-consented ([Phase 1, Registration 3](#registration-3-cloud-imaging-media-builder-desktop-public-client));
>    prevents `AADSTS650057` at sign-in.
> 2. The **`CloudImaging.MediaBuilderAccess` role assignment** to the user or group on the Operator
>    API enterprise application ([Phase 3, Step 2](#step-2-assign-access-to-your-administrators-and-technicians));
>    prevents `403` on API calls.

#### Installing the Windows ADK on technician workstations

Every workstation that will run **Generate Boot Image** needs the **Windows Assessment and
Deployment Kit (ADK)**. It is *not* bundled with Media Builder and must be installed
separately on each technician device (or baked into the device image).

The ADK ships as **two separate installers that must be the SAME version**:

| # | Installer | Run it, then select **only** |
|---|---|---|
| 1 | `adksetup.exe` (base ADK) | ☑ **Deployment Tools**; leave everything else (USMT, Windows Performance Toolkit, Application Compatibility Toolkit, VAMT, etc.) unchecked; Media Builder doesn't need them |
| 2 | `adkwinpesetup.exe` (WinPE add-on, downloaded and run *separately* after step 1) | ☑ **Windows Preinstallation Environment (WinPE)**; it's the only option |

Get both installers, matched to the same ADK release, from the official Microsoft page:
**<https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install>** (it links the
correct base ADK and WinPE add-on downloads for the current release together; don't mix an
older cached installer for one with a newer download for the other).

> **Why "Deployment Tools" specifically:** it's the feature that installs `DISM.exe`,
> `Oscdimg.exe`, and `copype.cmd`'s supporting environment (`DandISetEnv.bat`) under
> `Deployment Tools\<arch>\...`, everything Media Builder's boot image generation shells out
> to. The other ADK features (USMT, ACT, Windows Performance Toolkit, etc.) are unrelated to
> Cloud Imaging and only add install time/disk space.

> ⚠️ **The base ADK and the WinPE add-on version MUST match exactly.** They're installed and
> updated independently, so it's easy to end up with (for example) an older Deployment Tools
> paired with a newer WinPE add-on. When that happens, boot image generation fails deep inside
> Microsoft's `copype.cmd` with an error like *"Unable to copy boot sector file:
> ...\Deployment Tools\amd64\Oscdimg\efisys_EX.bin"*, the newer WinPE add-on's boot files
> reference boot-sector files that the older Deployment Tools release doesn't ship yet. Media
> Builder detects this specific mismatch and reports it clearly rather than surfacing the raw
> `copype.cmd` error, but the fix is always the same: **re-run `adksetup.exe` and update
> Deployment Tools to the same release as the WinPE add-on.**
>
> To check for a mismatch yourself, compare these two Add/Remove Programs entries; they must
> report the **same** version:
> ```powershell
> Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
>   Where-Object { $_.DisplayName -match 'Windows (Assessment and )?Deployment (Kit|Tools)$|WinPE Add-ons' } |
>   Select-Object DisplayName, DisplayVersion
> ```

Media Builder verifies the ADK + WinPE add-on are present (and blocks **Generate Boot Image**
with a link to the page above if not) before you can start a build.

#### Deploying the Media Builder with Intune

Every [GitHub Release](https://github.com/MSEndpointMgr/CloudImaging/releases) in the
`mse-ci-mediabuilder-v#.#.#` stream ships **`cloud-imaging-mediabuilder-<version>.msi`**, plus
`cloud-imaging-mediabuilder-<version>.zip` with identical content if you prefer your own packaging
process.

**1. Wrap the MSI** with the
[Microsoft Win32 Content Prep Tool](https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool):

```
IntuneWinAppUtil.exe -c <folder containing the msi> -s cloud-imaging-mediabuilder-<version>.msi -o <output folder>
```

**2. Create the Win32 app** (**Apps → Windows → Add → Windows app (Win32)**):

| Setting | Value |
|---|---|
| Install command | The single-line `msiexec` command from [Building the msiexec command line](#building-the-msiexec-command-line) |
| Uninstall command | `msiexec /x {ProductCode} /qn /norestart` |
| Install behavior | **System** (the app installs per-machine) |
| Detection rule | **MSI** → the product code, with *"MSI product version check"* set to greater-than-or-equal the version you are deploying |
| Requirement | 64-bit Windows |
| Dependency | Windows ADK + WinPE add-on |

The **Windows ADK + WinPE add-on** is deliberately not bundled in the MSI. Express it as an Intune
app dependency, or bake it into the technician device image.

##### What the MSI does

- Installs the self-contained app to `%ProgramFiles%\MSEndpointMgr\Cloud Imaging Media Builder`.
- Writes the configuration to `HKLM\SOFTWARE\MSEndpointMgr\CloudImaging\MediaBuilder`.
- Creates a Start menu shortcut for **all users**.
- Removes the app, the shortcut and the registry key on uninstall.
- On upgrade, carries the existing configuration forward: a newer MSI installed *without* the
  configuration properties reads the current values out of the registry and writes them back, so
  "deploy the new version" never blanks a working configuration. Properties supplied on the command
  line always win over the retained values.

Sign-in itself stays interactive per technician (MSAL loopback flow) and is unaffected by any of
the above.

---

## Phase 5: Operate Cloud Imaging

### Step 1: Generate Your First Boot Image

1. Open the **Cloud Imaging Media Builder** on a technician workstation with the Windows ADK
   + WinPE add-on installed (see [Installing the Windows ADK](#installing-the-windows-adk-on-technician-workstations))
2. Sign in with your Entra ID credentials (must have `CloudImaging.Administrator` or `CloudImaging.Technician` role)
3. Select **Generate Boot Image**
4. Choose **Auto-download** (fetches latest Cloud Imaging Client from GitHub) or specify a local path
5. Optionally check **Enable command prompt access** under **Support Tools** (see
   [Client support tools](#client-support-tools) below); off by default
6. Click **Generate**; the wizard produces a `.wim` file
7. Upload the WIM to the portal: **Boot Images** → **Upload**

> **Device Gateway URL is resolved automatically.** The Media Builder looks up the live Device
> Gateway API URL from the Operator API and stamps it into the Client's `appsettings.json` while
> building the WIM; there's nothing to configure manually, and every boot image build picks up
> the current URL even if the Device Gateway was redeployed or renamed since the Client binaries
> were built.

#### Client support tools

The Operation Selection screen offers two troubleshooting tools, both accessible without leaving
the always-on-top Cloud Imaging Client window:

- **Connect to Wi-Fi**: always available (no opt-in required). Opens a dedicated window that
  scans for visible networks via `netsh wlan` and lets the technician connect to an
  Open or WPA2/WPA3-Personal network by SSID + passphrase. Enterprise/802.1X networks are shown
  (greyed out, labeled "Not supported") but cannot be connected to via this flow. No Wi-Fi
  credential is ever persisted; the temporary WLAN profile (which embeds the passphrase in
  plain text, per the netsh profile schema) is deleted immediately after the connect attempt.
- **Command Prompt**: hidden unless the boot image was built with **Enable command prompt
  access** checked (off by default, per boot image). Launches an interactive `cmd.exe` for
  advanced troubleshooting, temporarily dropping the Client window's always-on-top behavior so
  the console isn't hidden behind it; the Client returns to always-on-top automatically once the
  console is closed.

> **Security note:** only enable command prompt access for boot images used in trusted,
> supervised environments (e.g. IT staging); an interactive shell in WinPE has full access to
> local disks and the network. Leave it unchecked for boot images that may be used unattended or
> by end users.

---

### Step 2: Prepare USB Media

1. In **Cloud Imaging Media Builder**, select **Prepare USB Storage Device**
2. Select the boot image to deploy
3. Insert a USB drive (32 GB+, USB 3.x)
4. Click **Prepare**; the drive will be partitioned and the WIM deployed

---

### Step 3: Image a Device

1. Boot the target device from the USB drive
2. The device auto-launches Cloud Imaging Client and displays a **passcode**
3. Sign in to the portal as a Technician
4. In the **Sessions** section, click **Couple Device** and enter the passcode
5. Click **Assign Image**, select an OS image, confirm
6. The device downloads and applies the image automatically

---

## Upgrading

Upgrading an existing deployment is a separate procedure with its own prerequisites, its own
dry-run step, and three release streams that are each upgraded differently. It has its own
guide: **[upgrade-instructions.md](upgrade-instructions.md)**.

---

## Getting Help

- **Upgrading an existing deployment**: [upgrade-instructions.md](upgrade-instructions.md)
- **Roles & access reference**: [roles-and-access.md](roles-and-access.md)
- **Troubleshooting**: [operations-runbook.md](operations-runbook.md)
- **Issues**: [GitHub Issues](https://github.com/MSEndpointMgr/CloudImaging/issues)
