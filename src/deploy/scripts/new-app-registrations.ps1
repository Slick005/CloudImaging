<#
.SYNOPSIS
    Creates (or repairs) the three Microsoft Entra app registrations Cloud Imaging needs, so
    Phase 1, Step 1 of the setup instructions is one command instead of a page of portal clicks.

.DESCRIPTION
    Creates the Cloud Imaging Portal, Operator API and Media Builder app registrations exactly as
    setup-instructions.md describes them, then prints the three client IDs the Template Spec
    wizard asks for:

        Portal         Single tenant, SPA redirect URI, api://<clientId> with the
                       user_impersonation scope, and the Administrator, Technician and Reader
                       app roles. Requests Microsoft Graph User.Read (profile photo only).
        Operator API   Single tenant, api://<clientId> with the user_impersonation scope, and
                       the PortalAccess (Applications) and MediaBuilderAccess (Users/Groups +
                       Applications) app roles.
        Media Builder  Single tenant, http://localhost public client redirect URI, the
                       Administrator and Technician app roles, and the delegated Operator API
                       user_impersonation permission.

    It also creates the enterprise application (service principal) behind each registration, and
    grants tenant-wide admin consent for the Media Builder's Operator API permission, which the
    guide otherwise has you do with the "Grant admin consent" button.

    Registrations are found by display name, so the script is safe to re-run. On an existing
    registration it only adds what is missing or fixes what is known to break sign-in (a disabled
    scope or role, a role missing a required member type, "Allow public client flows" set to Yes).
    It never deletes a role, scope, permission or redirect URI you added yourself, with one
    exception: once a real -PortalRedirectUri is supplied, the https://localhost placeholder is
    removed from the Portal.

    Re-run it after Phase 2 with -PortalRedirectUri set to the Static Web App URL to complete
    Phase 2, Step 3 (Update the Portal Redirect URI) as well.

    Sign-in requires consent for Application.ReadWrite.All, plus
    DelegatedPermissionGrant.ReadWrite.All unless -SkipAdminConsent is used. Creating the
    registrations needs Application Administrator or Cloud Application Administrator; granting
    the admin consent needs one of those or Privileged Role Administrator.

.PARAMETER DisplayNamePrefix
    Prefix for the three display names. The default produces "Cloud Imaging Portal",
    "Cloud Imaging Operator API" and "Cloud Imaging Media Builder".

.PARAMETER PortalRedirectUri
    SPA redirect URI for the Portal registration. Leave at the https://localhost placeholder
    before the deployment exists; after Phase 2, pass the Static Web App URL.

.PARAMETER TenantId
    Tenant (directory) ID or domain to sign in to. Recommended if you have access to more than one
    Entra tenant.

.PARAMETER SkipAdminConsent
    Do not grant tenant-wide admin consent for the Media Builder's Operator API permission. Use
    this when someone else holds the consent privilege; they then click "Grant admin consent" on
    the Media Builder registration's API permissions page.

.EXAMPLE
    .\scripts\new-app-registrations.ps1 -TenantId "contoso.onmicrosoft.com"

    Creates the three registrations with a placeholder Portal redirect URI.

.EXAMPLE
    .\scripts\new-app-registrations.ps1 -TenantId "contoso.onmicrosoft.com" -PortalRedirectUri "https://<swa-name>.azurestaticapps.net"

    After Phase 2: points the Portal at the deployed Static Web App and removes the placeholder.

.NOTES
    FileName:    new-app-registrations.ps1
    Author:      MSEndpointMgr
    Contact:     @MSEndpointMgr
    Created:     2026-10-03
    Updated:     2026-10-03

    Version history:
    1.0.0 - (2026-10-03) Initial release
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Prefix for the three registration display names.")]
    [ValidateNotNullOrEmpty()]
    [string] $DisplayNamePrefix = "Cloud Imaging",
    [Parameter(Mandatory = $false, HelpMessage = "SPA redirect URI for the Portal registration.")]
    [ValidatePattern("^https://")]
    [string] $PortalRedirectUri = "https://localhost",
    [Parameter(Mandatory = $false, HelpMessage = "Tenant ID or domain to sign in to.")]
    [string] $TenantId,
    [Parameter(Mandatory = $false, HelpMessage = "Do not grant admin consent for the Media Builder's Operator API permission.")]
    [switch] $SkipAdminConsent
)

$ErrorActionPreference = "Stop"

$PlaceholderRedirectUri = "https://localhost"
$MediaBuilderRedirectUri = "http://localhost"
$GraphAppId = "00000003-0000-0000-c000-000000000000"
# Microsoft Graph's delegated User.Read scope. The ID is the same in every tenant.
$GraphUserReadScopeId = "e1fd296f-fa3e-4f5d-b8a0-b2f2b5de6a62"
$ScopeName = "user_impersonation"

function Get-CloudImagingRegistrationSpec {
    <#
        Desired state of the three registrations, taken from setup-instructions.md, Phase 1,
        Step 1. Keyed by the short name used throughout this script.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string] $DisplayNamePrefix
    )
    return [ordered]@{
        OperatorApi  = @{
            DisplayName = "$($DisplayNamePrefix) Operator API"
            ExposeApi   = $true
            Scope       = @{
                AdminConsentDisplayName = "Access Cloud Imaging Operator API"
                AdminConsentDescription = "Allows the app to access the Cloud Imaging Operator API on behalf of the signed-in user."
            }
            AppRoles    = @(
                @{ Value = "CloudImaging.PortalAccess"; AllowedMemberTypes = @("Application"); Description = "Lets the Portal backend's managed identity call the Operator API on the signed-in user's behalf." }
                @{ Value = "CloudImaging.MediaBuilderAccess"; AllowedMemberTypes = @("User", "Application"); Description = "Lets a signed-in technician's Media Builder client call the Operator API." }
            )
        }
        Portal       = @{
            DisplayName = "$($DisplayNamePrefix) Portal"
            ExposeApi   = $true
            Scope       = @{
                AdminConsentDisplayName = "Access Cloud Imaging Portal backend"
                AdminConsentDescription = "Allows the app to access the Cloud Imaging Portal backend on behalf of the signed-in user."
            }
            AppRoles    = @(
                @{ Value = "CloudImaging.Administrator"; AllowedMemberTypes = @("User"); Description = "Full access to Cloud Imaging: catalog writes, branding, configuration, and the boot-media certificate." }
                @{ Value = "CloudImaging.Technician"; AllowedMemberTypes = @("User"); Description = "Day-to-day imaging operations: sessions, coupling, assignment, and read-only catalogs." }
                @{ Value = "CloudImaging.Reader"; AllowedMemberTypes = @("User"); Description = "Read-only access to the Dashboard and Reports." }
            )
        }
        MediaBuilder = @{
            DisplayName = "$($DisplayNamePrefix) Media Builder"
            ExposeApi   = $false
            AppRoles    = @(
                @{ Value = "CloudImaging.Administrator"; AllowedMemberTypes = @("User"); Description = "Full Media Builder access: generate boot images (embeds the active boot-media certificate and branding) and prepare USB storage devices." }
                @{ Value = "CloudImaging.Technician"; AllowedMemberTypes = @("User"); Description = "Prepare USB storage devices with an already-published boot image. Cannot generate new boot images (Administrator-only)." }
            )
        }
    }
}

function ConvertTo-AppRoleBody {
    param ([Parameter(Mandatory = $true)] $AppRole)
    return @{
        id                 = [string] $AppRole.Id
        value              = $AppRole.Value
        displayName        = $AppRole.DisplayName
        description        = $AppRole.Description
        allowedMemberTypes = @($AppRole.AllowedMemberTypes)
        isEnabled          = [bool] $AppRole.IsEnabled
    }
}

function ConvertTo-ScopeBody {
    param ([Parameter(Mandatory = $true)] $Scope)
    return @{
        id                      = [string] $Scope.Id
        value                   = $Scope.Value
        type                    = $Scope.Type
        isEnabled               = [bool] $Scope.IsEnabled
        adminConsentDisplayName = $Scope.AdminConsentDisplayName
        adminConsentDescription = $Scope.AdminConsentDescription
        userConsentDisplayName  = $Scope.UserConsentDisplayName
        userConsentDescription  = $Scope.UserConsentDescription
    }
}

function Get-AppRegistrationPatch {
    <#
        Compares an existing application with its spec and returns the Update-MgApplication body
        that brings it in line, plus a human-readable list of what that body changes. An empty
        Body means the registration is already correct. Pure, so it is unit tested without Graph.
    #>
    param (
        [Parameter(Mandatory = $true)] $Application,
        [Parameter(Mandatory = $true)] [hashtable] $Spec,
        [Parameter(Mandatory = $true)] [ValidateSet("Portal", "OperatorApi", "MediaBuilder")] [string] $Kind,
        [Parameter(Mandatory = $false)] [string] $PortalRedirectUri = $PlaceholderRedirectUri,
        [Parameter(Mandatory = $false)] [string] $OperatorApiAppId,
        [Parameter(Mandatory = $false)] [string] $OperatorApiScopeId,
        [Parameter(Mandatory = $false)] [scriptblock] $NewId = { [guid]::NewGuid().ToString() }
    )
    $Body = @{}
    $Changes = New-Object -TypeName "System.Collections.Generic.List[string]"
    $Warnings = New-Object -TypeName "System.Collections.Generic.List[string]"

    if ($Application.SignInAudience -ne "AzureADMyOrg") {
        $Body.signInAudience = "AzureADMyOrg"
        $Changes.Add("Set supported account types to single tenant")
    }

    if ($Application.IsFallbackPublicClient -eq $true) {
        $Body.isFallbackPublicClient = $false
        $Changes.Add("Set 'Allow public client flows' to No")
    }

    if ($Spec.ExposeApi) {
        if (-not @($Application.IdentifierUris | Where-Object { $PSItem })) {
            $Body.identifierUris = @("api://$($Application.AppId)")
            $Changes.Add("Set Application ID URI to api://$($Application.AppId)")
        }

        $Scopes = @($Application.Api.Oauth2PermissionScopes | Where-Object { $PSItem } | ForEach-Object { ConvertTo-ScopeBody -Scope $PSItem })
        $Existing = $Scopes | Where-Object { $PSItem.value -eq $ScopeName } | Select-Object -First 1
        $ScopesChanged = $false
        if ($null -eq $Existing) {
            $Scopes += @{
                id                      = & $NewId
                value                   = $ScopeName
                type                    = "User"
                isEnabled               = $true
                adminConsentDisplayName = $Spec.Scope.AdminConsentDisplayName
                adminConsentDescription = $Spec.Scope.AdminConsentDescription
                userConsentDisplayName  = $null
                userConsentDescription  = $null
            }
            $ScopesChanged = $true
            $Changes.Add("Added scope '$($ScopeName)'")
        }
        elseif (-not $Existing.isEnabled) {
            $Existing.isEnabled = $true
            $ScopesChanged = $true
            $Changes.Add("Enabled scope '$($ScopeName)'")
        }
        if ($ScopesChanged) {
            # A PATCH replaces the whole api object, so carry over the settings this script
            # doesn't manage rather than resetting them to their defaults.
            $Body.api = @{ oauth2PermissionScopes = $Scopes }
            if ($null -ne $Application.Api.RequestedAccessTokenVersion) {
                $Body.api.requestedAccessTokenVersion = $Application.Api.RequestedAccessTokenVersion
            }
            if ($null -ne $Application.Api.AcceptMappedClaims) {
                $Body.api.acceptMappedClaims = $Application.Api.AcceptMappedClaims
            }
            if (@($Application.Api.KnownClientApplications | Where-Object { $PSItem }).Count -gt 0) {
                $Body.api.knownClientApplications = @($Application.Api.KnownClientApplications)
            }
            if (@($Application.Api.PreAuthorizedApplications | Where-Object { $PSItem }).Count -gt 0) {
                $Body.api.preAuthorizedApplications = @($Application.Api.PreAuthorizedApplications | ForEach-Object {
                        @{ appId = $PSItem.AppId; delegatedPermissionIds = @($PSItem.DelegatedPermissionIds) }
                    })
            }
        }
    }

    $Roles = @($Application.AppRoles | Where-Object { $PSItem } | ForEach-Object { ConvertTo-AppRoleBody -AppRole $PSItem })
    $RolesChanged = $false
    foreach ($RoleSpec in $Spec.AppRoles) {
        $Existing = $Roles | Where-Object { $PSItem.value -eq $RoleSpec.Value } | Select-Object -First 1
        if ($null -eq $Existing) {
            $Roles += @{
                id                 = & $NewId
                value              = $RoleSpec.Value
                displayName        = $RoleSpec.Value
                description        = $RoleSpec.Description
                allowedMemberTypes = @($RoleSpec.AllowedMemberTypes)
                isEnabled          = $true
            }
            $RolesChanged = $true
            $Changes.Add("Added app role '$($RoleSpec.Value)'")
            continue
        }
        $MissingTypes = @($RoleSpec.AllowedMemberTypes | Where-Object { $PSItem -notin $Existing.allowedMemberTypes })
        if ($MissingTypes.Count -gt 0) {
            $Existing.allowedMemberTypes = @($Existing.allowedMemberTypes) + $MissingTypes
            $RolesChanged = $true
            $Changes.Add("Allowed '$($MissingTypes -join "', '")' on app role '$($RoleSpec.Value)'")
        }
        if (-not $Existing.isEnabled) {
            $Existing.isEnabled = $true
            $RolesChanged = $true
            $Changes.Add("Enabled app role '$($RoleSpec.Value)'")
        }
    }
    if ($RolesChanged) {
        $Body.appRoles = $Roles
    }

    $RequiredAccess = @($Application.RequiredResourceAccess | Where-Object { $PSItem } | ForEach-Object {
            @{
                resourceAppId  = $PSItem.ResourceAppId
                resourceAccess = @($PSItem.ResourceAccess | ForEach-Object { @{ id = [string] $PSItem.Id; type = $PSItem.Type } })
            }
        })
    $Permission = $null
    switch ($Kind) {
        "Portal" { $Permission = @{ ResourceAppId = $GraphAppId; Id = $GraphUserReadScopeId; Label = "Microsoft Graph User.Read" } }
        "MediaBuilder" {
            if ($OperatorApiAppId -and $OperatorApiScopeId) {
                $Permission = @{ ResourceAppId = $OperatorApiAppId; Id = $OperatorApiScopeId; Label = "Operator API $($ScopeName)" }
            }
        }
    }
    if ($null -ne $Permission) {
        $Resource = $RequiredAccess | Where-Object { $PSItem.resourceAppId -eq $Permission.ResourceAppId } | Select-Object -First 1
        if ($null -eq $Resource) {
            $Resource = @{ resourceAppId = $Permission.ResourceAppId; resourceAccess = @() }
            $RequiredAccess += $Resource
        }
        if (-not ($Resource.resourceAccess | Where-Object { $PSItem.id -eq $Permission.Id })) {
            $Resource.resourceAccess = @($Resource.resourceAccess) + @{ id = $Permission.Id; type = "Scope" }
            $Body.requiredResourceAccess = $RequiredAccess
            $Changes.Add("Requested delegated permission $($Permission.Label)")
        }
    }

    switch ($Kind) {
        "Portal" {
            $Uris = @($Application.Spa.RedirectUris | Where-Object { $PSItem })
            if ($PortalRedirectUri -eq $PlaceholderRedirectUri) {
                # Re-running without -PortalRedirectUri must never put the placeholder back next
                # to a real URI, so it is only added to a registration that has none at all.
                $Desired = if ($Uris.Count -gt 0) { $Uris } else { @($PlaceholderRedirectUri) }
            }
            else {
                $Desired = @($Uris | Where-Object { $PSItem -ne $PlaceholderRedirectUri })
                if ($PortalRedirectUri -notin $Desired) {
                    $Desired += $PortalRedirectUri
                }
            }
            if (($Uris -join "|") -ne ($Desired -join "|")) {
                $Body.spa = @{ redirectUris = @($Desired) }
                if ($Desired[-1] -notin $Uris) { $Changes.Add("Added SPA redirect URI $($Desired[-1])") }
                if ($Uris -contains $PlaceholderRedirectUri -and $Desired -notcontains $PlaceholderRedirectUri) {
                    $Changes.Add("Removed placeholder SPA redirect URI $($PlaceholderRedirectUri)")
                }
            }
            if (@($Application.PublicClient.RedirectUris | Where-Object { $PSItem }).Count -gt 0) {
                $Warnings.Add("The Portal registration has a Mobile and desktop platform, which breaks portal sign-in with AADSTS9002326. Remove it under Authentication; this script does not delete it for you.")
            }
        }
        "MediaBuilder" {
            $Uris = @($Application.PublicClient.RedirectUris | Where-Object { $PSItem })
            if ($MediaBuilderRedirectUri -notin $Uris) {
                $Body.publicClient = @{ redirectUris = @($Uris) + $MediaBuilderRedirectUri }
                $Changes.Add("Added Mobile and desktop redirect URI $($MediaBuilderRedirectUri)")
            }
        }
    }

    return [PSCustomObject]@{
        Body     = $Body
        Changes  = @($Changes)
        Warnings = @($Warnings)
    }
}

function Invoke-WithRetry {
    <#
        A registration just created is not always visible to the next Graph call yet (service
        principal creation in particular fails with "does not reference a valid application
        object"), so dependent calls are retried while Entra replicates.
    #>
    param (
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $false)] [int] $MaxAttempts = 6,
        [Parameter(Mandatory = $false)] [int] $DelaySeconds = 5
    )
    for ($Attempt = 1; ; $Attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($Attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-ApplicationByDisplayName {
    param ([Parameter(Mandatory = $true)] [string] $DisplayName)
    $Escaped = $DisplayName.Replace("'", "''")
    $Found = @(Get-MgApplication -Filter "displayName eq '$($Escaped)'" -All)
    if ($Found.Count -gt 1) {
        throw "Found $($Found.Count) app registrations named '$($DisplayName)'. Delete or rename the extras, or use -DisplayNamePrefix to pick different names, then run this script again."
    }
    return $Found | Select-Object -First 1
}

function Assert-GraphModule {
    $AuthModule = Get-Module -ListAvailable Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
    $AppsModule = Get-Module -ListAvailable Microsoft.Graph.Applications | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $AuthModule -or -not $AppsModule) {
        throw "Microsoft Graph PowerShell modules are missing. Run: Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser"
    }
    # Mixing majors makes every Graph call fail with the useless "One or more errors occurred".
    if ($AuthModule.Version.Major -ne $AppsModule.Version.Major) {
        throw "Microsoft.Graph.Authentication $($AuthModule.Version) and Microsoft.Graph.Applications $($AppsModule.Version) are different major versions. Run: Update-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications"
    }
}

# Dot-sourcing loads the functions above for the Pester tests without touching a tenant.
if ($MyInvocation.InvocationName -eq ".") {
    return
}

$Results = New-Object -TypeName "System.Collections.Generic.List[System.Object]"
$FailureCount = 0

function Add-Result {
    param ([string] $Registration, [string] $Step, [string] $Status, [string] $Detail = "")
    $Results.Add([PSCustomObject]@{
            Registration = $Registration
            Step         = $Step
            Status       = $Status
            Detail       = $Detail
        })
}

Assert-GraphModule

$RequiredScopes = @("Application.ReadWrite.All")
if (-not $SkipAdminConsent) {
    $RequiredScopes += "DelegatedPermissionGrant.ReadWrite.All"
}

$GraphContext = Get-MgContext
$MissingScopes = @()
if ($null -ne $GraphContext) {
    $MissingScopes = @($RequiredScopes | Where-Object { $PSItem -notin $GraphContext.Scopes })
}
if ($null -eq $GraphContext -or $MissingScopes.Count -gt 0 -or ($TenantId -and $GraphContext.TenantId -ne $TenantId)) {
    Write-Host "Connecting to Microsoft Graph, a browser sign-in will open"
    $ConnectParams = @{ Scopes = $RequiredScopes; NoWelcome = $true }
    if ($TenantId) { $ConnectParams.TenantId = $TenantId }
    Connect-MgGraph @ConnectParams
    $GraphContext = Get-MgContext
}

Write-Host "Cloud Imaging app registrations"
Write-Host "Tenant: $($GraphContext.TenantId)"
Write-Host "Account: $($GraphContext.Account)"
Write-Host ""

$Specs = Get-CloudImagingRegistrationSpec -DisplayNamePrefix $DisplayNamePrefix
$Applications = @{}
$ServicePrincipals = @{}

# The Operator API goes first: the Media Builder's permission references its scope ID.
foreach ($Kind in $Specs.Keys) {
    $Spec = $Specs[$Kind]
    Write-Host "=== $($Spec.DisplayName) ==="
    try {
        $Application = Get-ApplicationByDisplayName -DisplayName $Spec.DisplayName
        if ($null -eq $Application) {
            if (-not $PSCmdlet.ShouldProcess($Spec.DisplayName, "Create app registration")) {
                Add-Result -Registration $Spec.DisplayName -Step "Registration" -Status "Would create"
                continue
            }
            $Application = New-MgApplication -BodyParameter @{ displayName = $Spec.DisplayName; signInAudience = "AzureADMyOrg" }
            Write-Host "  Created, client ID $($Application.AppId)"
            Add-Result -Registration $Spec.DisplayName -Step "Registration" -Status "Created" -Detail $Application.AppId
        }
        else {
            Write-Host "  Found existing registration, client ID $($Application.AppId)"
            Add-Result -Registration $Spec.DisplayName -Step "Registration" -Status "Already present" -Detail $Application.AppId
        }

        $PatchParams = @{
            Application       = $Application
            Spec              = $Spec
            Kind              = $Kind
            PortalRedirectUri = $PortalRedirectUri
        }
        if ($Kind -eq "MediaBuilder" -and $Applications.ContainsKey("OperatorApi")) {
            $OperatorScope = $Applications.OperatorApi.Api.Oauth2PermissionScopes | Where-Object { $PSItem.Value -eq $ScopeName } | Select-Object -First 1
            $PatchParams.OperatorApiAppId = $Applications.OperatorApi.AppId
            $PatchParams.OperatorApiScopeId = [string] $OperatorScope.Id
        }
        $Patch = Get-AppRegistrationPatch @PatchParams
        foreach ($Warning in $Patch.Warnings) {
            Write-Warning -Message $Warning
        }

        if ($Patch.Body.Count -eq 0) {
            Add-Result -Registration $Spec.DisplayName -Step "Configuration" -Status "Already correct"
        }
        elseif ($PSCmdlet.ShouldProcess($Spec.DisplayName, "Update app registration: $($Patch.Changes -join '; ')")) {
            Invoke-WithRetry -ScriptBlock { Update-MgApplication -ApplicationId $Application.Id -BodyParameter $Patch.Body }
            $Patch.Changes | ForEach-Object { Write-Host "  $($PSItem)" }
            # Read back so the next registration (and the summary) sees what Entra actually stored.
            $Application = Invoke-WithRetry -ScriptBlock { Get-MgApplication -ApplicationId $Application.Id }
            Add-Result -Registration $Spec.DisplayName -Step "Configuration" -Status "Updated" -Detail ($Patch.Changes -join "; ")
        }
        else {
            Add-Result -Registration $Spec.DisplayName -Step "Configuration" -Status "Would update" -Detail ($Patch.Changes -join "; ")
        }
        $Applications[$Kind] = $Application

        # The enterprise application is what users and groups are assigned to in Phase 3, Step 2,
        # and what admin consent is recorded against.
        $ServicePrincipal = Get-MgServicePrincipal -Filter "appId eq '$($Application.AppId)'" | Select-Object -First 1
        if ($null -ne $ServicePrincipal) {
            Add-Result -Registration $Spec.DisplayName -Step "Enterprise application" -Status "Already present"
        }
        elseif ($PSCmdlet.ShouldProcess($Spec.DisplayName, "Create enterprise application")) {
            $ServicePrincipal = Invoke-WithRetry -ScriptBlock { New-MgServicePrincipal -BodyParameter @{ appId = $Application.AppId } }
            Add-Result -Registration $Spec.DisplayName -Step "Enterprise application" -Status "Created"
        }
        else {
            Add-Result -Registration $Spec.DisplayName -Step "Enterprise application" -Status "Would create"
        }
        if ($null -ne $ServicePrincipal) {
            $ServicePrincipals[$Kind] = $ServicePrincipal
        }
    }
    catch {
        $FailureCount++
        Write-Warning -Message "$($Spec.DisplayName): $($_.Exception.Message)"
        Add-Result -Registration $Spec.DisplayName -Step "Registration" -Status "Failed" -Detail $_.Exception.Message
    }
    Write-Host ""
}

# Admin consent for the Media Builder's delegated Operator API permission (Registration 3,
# step 7). An AllPrincipals grant is exactly what the portal's "Grant admin consent" button makes.
$ConsentLabel = "$($Specs.MediaBuilder.DisplayName)"
if ($SkipAdminConsent) {
    Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Skipped" -Detail "Click 'Grant admin consent' on the API permissions page"
}
elseif (-not ($ServicePrincipals.ContainsKey("MediaBuilder") -and $ServicePrincipals.ContainsKey("OperatorApi"))) {
    Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Not attempted" -Detail "The registrations above are not all in place"
}
else {
    try {
        $ClientId = $ServicePrincipals.MediaBuilder.Id
        $ResourceId = $ServicePrincipals.OperatorApi.Id
        $Filter = [uri]::EscapeDataString("clientId eq '$($ClientId)' and resourceId eq '$($ResourceId)' and consentType eq 'AllPrincipals'")
        $Grant = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$($Filter)").value | Select-Object -First 1
        $GrantedScopes = @(if ($null -ne $Grant) { "$($Grant.scope)" -split " " | Where-Object { $PSItem } })
        if ($GrantedScopes -contains $ScopeName) {
            Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Already present"
        }
        elseif (-not $PSCmdlet.ShouldProcess($ConsentLabel, "Grant admin consent for Operator API $($ScopeName)")) {
            Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Would grant"
        }
        elseif ($null -ne $Grant) {
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($Grant.id)" -Body (@{ scope = (@($GrantedScopes) + $ScopeName) -join " " } | ConvertTo-Json) -ContentType "application/json" | Out-Null
            Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Granted"
        }
        else {
            $GrantBody = @{
                clientId    = $ClientId
                consentType = "AllPrincipals"
                resourceId  = $ResourceId
                scope       = $ScopeName
            }
            Invoke-WithRetry -ScriptBlock {
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" -Body ($GrantBody | ConvertTo-Json) -ContentType "application/json"
            } | Out-Null
            Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Granted"
        }
    }
    catch {
        $FailureCount++
        Write-Warning -Message "Could not grant admin consent: $($_.Exception.Message)"
        Add-Result -Registration $ConsentLabel -Step "Admin consent" -Status "Failed" -Detail "$($_.Exception.Message) Ask an administrator to click 'Grant admin consent' on the Media Builder's API permissions page, or re-run with their account."
    }
}

Write-Host "Summary"
Write-Host ($Results | Format-Table -AutoSize -Wrap | Out-String).TrimEnd()
Write-Host ""

$Output = [PSCustomObject]@{
    PortalClientId       = $Applications.Portal.AppId
    OperatorApiClientId  = $Applications.OperatorApi.AppId
    MediaBuilderClientId = $Applications.MediaBuilder.AppId
    TenantId             = $GraphContext.TenantId
}

if ($FailureCount -gt 0) {
    Write-Warning -Message "$($FailureCount) step(s) did not complete. Resolve the errors above and run this script again, it is safe to re-run."
}
elseif ($Output.PortalClientId -and $Output.OperatorApiClientId -and $Output.MediaBuilderClientId) {
    Write-Host "Enter these in the Template Spec wizard (Phase 2, Step 2):"
    Write-Host "  portalClientId       $($Output.PortalClientId)"
    Write-Host "  operatorApiClientId  $($Output.OperatorApiClientId)"
    Write-Host "  mediaBuilderClientId $($Output.MediaBuilderClientId)"
    Write-Host ""
    Write-Host "To double-check them:"
    Write-Host "  .\scripts\verify-app-registrations.ps1 -PortalClientId `"$($Output.PortalClientId)`" -OperatorApiClientId `"$($Output.OperatorApiClientId)`" -MediaBuilderClientId `"$($Output.MediaBuilderClientId)`" -TenantId `"$($Output.TenantId)`""
}

$Output
