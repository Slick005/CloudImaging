#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.5.0" }

BeforeAll {
    $ScriptPath = Join-Path $PSScriptRoot "../../src/deploy/scripts/new-app-registrations.ps1"
    . $ScriptPath

    $Spec = Get-CloudImagingRegistrationSpec -DisplayNamePrefix "Cloud Imaging"

    # Graph SDK objects expose PascalCase properties; bodies sent to Graph are camelCase. The fake
    # tenant stores camelCase (as Graph does) and hands back PascalCase objects, like the SDK.
    function ConvertTo-GraphObject {
        param ($Value)
        if ($Value -is [System.Collections.IDictionary]) {
            $Props = [ordered]@{}
            foreach ($Key in $Value.Keys) {
                $Props[$Key.Substring(0, 1).ToUpper() + $Key.Substring(1)] = ConvertTo-GraphObject $Value[$Key]
            }
            return [PSCustomObject]$Props
        }
        if ($Value -is [array]) {
            return , @($Value | ForEach-Object { ConvertTo-GraphObject $PSItem })
        }
        return $Value
    }

    function New-FakeApplication {
        param ([hashtable] $Properties = @{})
        $App = @{
            id                     = [guid]::NewGuid().ToString()
            appId                  = [guid]::NewGuid().ToString()
            displayName            = "Test"
            signInAudience         = "AzureADMyOrg"
            isFallbackPublicClient = $null
            identifierUris         = @()
            api                    = @{ oauth2PermissionScopes = @() }
            appRoles               = @()
            spa                    = @{ redirectUris = @() }
            publicClient           = @{ redirectUris = @() }
            requiredResourceAccess = @()
        }
        foreach ($Key in $Properties.Keys) { $App[$Key] = $Properties[$Key] }
        return ConvertTo-GraphObject $App
    }

    # Stand-ins for the Microsoft Graph cmdlets, for Pester to mock. They are always used, even
    # where the Graph modules are installed (as on the GitHub runners): the real cmdlets bind
    # -BodyParameter to typed Graph models, which hides the hashtable bodies the fake tenant
    # stores. Functions take precedence over cmdlets, and mocks take their parameters from the
    # command they replace, so each stub declares the parameters the script passes.
    $Stubs = @{
        "Get-MgApplication"      = { param ($Filter, [switch] $All, $ApplicationId) throw "Not mocked" }
        "New-MgApplication"      = { param ($BodyParameter) throw "Not mocked" }
        "Update-MgApplication"   = { param ($ApplicationId, $BodyParameter) throw "Not mocked" }
        "Get-MgServicePrincipal" = { param ($Filter) throw "Not mocked" }
        "New-MgServicePrincipal" = { param ($BodyParameter) throw "Not mocked" }
        "Get-MgContext"          = { throw "Not mocked" }
        "Connect-MgGraph"        = { param ($Scopes, $TenantId, [switch] $NoWelcome) throw "Not mocked" }
        "Invoke-MgGraphRequest"  = { param ($Method, $Uri, $Body, $ContentType) throw "Not mocked" }
    }
    foreach ($Command in $Stubs.Keys) {
        New-Item -Path "function:global:$Command" -Value $Stubs[$Command] -Force | Out-Null
    }
}

AfterAll {
    foreach ($Command in $Stubs.Keys) {
        Remove-Item -Path "function:global:$Command" -ErrorAction SilentlyContinue
    }
}

Describe "Get-AppRegistrationPatch" {
    It "configures a freshly created Operator API registration completely" {
        $App = New-FakeApplication
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.OperatorApi -Kind OperatorApi

        $Patch.Body.identifierUris | Should -Be @("api://$($App.AppId)")
        $Patch.Body.api.oauth2PermissionScopes.value | Should -Be "user_impersonation"
        $Patch.Body.api.oauth2PermissionScopes[0].isEnabled | Should -BeTrue
        $Patch.Body.api.oauth2PermissionScopes[0].type | Should -Be "User"
        $Patch.Body.appRoles.value | Should -Be @("CloudImaging.PortalAccess", "CloudImaging.MediaBuilderAccess")
        ($Patch.Body.appRoles | Where-Object value -eq "CloudImaging.PortalAccess").allowedMemberTypes | Should -Be @("Application")
        ($Patch.Body.appRoles | Where-Object value -eq "CloudImaging.MediaBuilderAccess").allowedMemberTypes | Should -Be @("User", "Application")
        $Patch.Body.ContainsKey("spa") | Should -BeFalse
        $Patch.Body.ContainsKey("publicClient") | Should -BeFalse
        $Patch.Body.ContainsKey("requiredResourceAccess") | Should -BeFalse
    }

    It "configures a freshly created Portal registration completely" {
        $App = New-FakeApplication
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal

        $Patch.Body.spa.redirectUris | Should -Be @("https://localhost")
        $Patch.Body.appRoles.value | Should -Be @("CloudImaging.Administrator", "CloudImaging.Technician", "CloudImaging.Reader")
        $Patch.Body.appRoles | ForEach-Object { $PSItem.allowedMemberTypes | Should -Be @("User") }
        $Patch.Body.api.oauth2PermissionScopes.adminConsentDisplayName | Should -Be "Access Cloud Imaging Portal backend"
        $Patch.Body.requiredResourceAccess.resourceAppId | Should -Be "00000003-0000-0000-c000-000000000000"
        $Patch.Body.requiredResourceAccess.resourceAccess.id | Should -Be "e1fd296f-fa3e-4f5d-b8a0-b2f2b5de6a62"
        $Patch.Body.ContainsKey("publicClient") | Should -BeFalse
    }

    It "configures a freshly created Media Builder registration completely" {
        $App = New-FakeApplication
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.MediaBuilder -Kind MediaBuilder -OperatorApiAppId "op-app" -OperatorApiScopeId "op-scope"

        $Patch.Body.publicClient.redirectUris | Should -Be @("http://localhost")
        $Patch.Body.ContainsKey("identifierUris") | Should -BeFalse
        $Patch.Body.ContainsKey("api") | Should -BeFalse
        $Patch.Body.appRoles.value | Should -Be @("CloudImaging.Administrator", "CloudImaging.Technician")
        $Patch.Body.requiredResourceAccess.resourceAppId | Should -Be "op-app"
        $Patch.Body.requiredResourceAccess[0].resourceAccess[0].id | Should -Be "op-scope"
        $Patch.Body.requiredResourceAccess[0].resourceAccess[0].type | Should -Be "Scope"
    }

    It "skips the Media Builder permission when the Operator API is not known yet" {
        $Patch = Get-AppRegistrationPatch -Application (New-FakeApplication) -Spec $Spec.MediaBuilder -Kind MediaBuilder
        $Patch.Body.ContainsKey("requiredResourceAccess") | Should -BeFalse
    }

    It "returns an empty patch for a registration that is already correct" {
        $App = New-FakeApplication
        $First = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal
        $Configured = New-FakeApplication -Properties (@{ appId = $App.AppId } + $First.Body)

        $Second = Get-AppRegistrationPatch -Application $Configured -Spec $Spec.Portal -Kind Portal
        $Second.Body.Count | Should -Be 0
        $Second.Changes | Should -BeNullOrEmpty
    }

    It "keeps existing roles, scopes and IDs and only adds what is missing" {
        $App = New-FakeApplication -Properties @{
            identifierUris = @("api://custom")
            api            = @{ oauth2PermissionScopes = @(@{ id = "scope-1"; value = "user_impersonation"; type = "User"; isEnabled = $true }) }
            appRoles       = @(
                @{ id = "role-1"; value = "CloudImaging.PortalAccess"; displayName = "x"; description = "x"; allowedMemberTypes = @("Application"); isEnabled = $true }
                @{ id = "role-2"; value = "Custom.Role"; displayName = "x"; description = "x"; allowedMemberTypes = @("User"); isEnabled = $true }
            )
        }
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.OperatorApi -Kind OperatorApi

        $Patch.Body.ContainsKey("identifierUris") | Should -BeFalse
        $Patch.Body.ContainsKey("api") | Should -BeFalse
        $Patch.Body.appRoles.id | Should -Contain "role-1"
        $Patch.Body.appRoles.value | Should -Contain "Custom.Role"
        $Patch.Body.appRoles.value | Should -Contain "CloudImaging.MediaBuilderAccess"
        $Patch.Changes | Should -Be @("Added app role 'CloudImaging.MediaBuilderAccess'")
    }

    It "adds the missing Users/Groups member type to MediaBuilderAccess (the 403 mistake)" {
        $App = New-FakeApplication -Properties @{
            identifierUris = @("api://x")
            api            = @{ oauth2PermissionScopes = @(@{ id = "s"; value = "user_impersonation"; type = "User"; isEnabled = $true }) }
            appRoles       = @(
                @{ id = "r1"; value = "CloudImaging.PortalAccess"; allowedMemberTypes = @("Application"); isEnabled = $true }
                @{ id = "r2"; value = "CloudImaging.MediaBuilderAccess"; allowedMemberTypes = @("Application"); isEnabled = $true }
            )
        }
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.OperatorApi -Kind OperatorApi

        ($Patch.Body.appRoles | Where-Object id -eq "r2").allowedMemberTypes | Should -Be @("Application", "User")
    }

    It "re-enables a disabled scope and app role" {
        $App = New-FakeApplication -Properties @{
            identifierUris = @("api://x")
            api            = @{ oauth2PermissionScopes = @(@{ id = "s"; value = "user_impersonation"; type = "User"; isEnabled = $false }) }
            appRoles       = @(
                @{ id = "r1"; value = "CloudImaging.PortalAccess"; allowedMemberTypes = @("Application"); isEnabled = $false }
                @{ id = "r2"; value = "CloudImaging.MediaBuilderAccess"; allowedMemberTypes = @("User", "Application"); isEnabled = $true }
            )
        }
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.OperatorApi -Kind OperatorApi

        $Patch.Body.api.oauth2PermissionScopes[0].id | Should -Be "s"
        $Patch.Body.api.oauth2PermissionScopes[0].isEnabled | Should -BeTrue
        ($Patch.Body.appRoles | Where-Object id -eq "r1").isEnabled | Should -BeTrue
    }

    It "keeps the other api settings when it has to rewrite the scope list" {
        $App = New-FakeApplication -Properties @{
            api = @{
                oauth2PermissionScopes      = @()
                requestedAccessTokenVersion = 2
                preAuthorizedApplications   = @(@{ appId = "pre-app"; delegatedPermissionIds = @("p1") })
            }
        }
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.OperatorApi -Kind OperatorApi

        $Patch.Body.api.requestedAccessTokenVersion | Should -Be 2
        $Patch.Body.api.preAuthorizedApplications[0].appId | Should -Be "pre-app"
        $Patch.Body.api.preAuthorizedApplications[0].delegatedPermissionIds | Should -Be @("p1")
    }

    It "turns off 'Allow public client flows' and forces single tenant" {
        $App = New-FakeApplication -Properties @{ isFallbackPublicClient = $true; signInAudience = "AzureADMultipleOrgs" }
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.MediaBuilder -Kind MediaBuilder

        $Patch.Body.isFallbackPublicClient | Should -BeFalse
        $Patch.Body.signInAudience | Should -Be "AzureADMyOrg"
    }

    It "keeps other Graph permissions when adding User.Read to the Portal" {
        $App = New-FakeApplication -Properties @{
            requiredResourceAccess = @(@{ resourceAppId = "00000003-0000-0000-c000-000000000000"; resourceAccess = @(@{ id = "other"; type = "Scope" }) })
        }
        $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal

        $Patch.Body.requiredResourceAccess.Count | Should -Be 1
        $Patch.Body.requiredResourceAccess[0].resourceAccess.id | Should -Be @("other", "e1fd296f-fa3e-4f5d-b8a0-b2f2b5de6a62")
    }

    Context "Portal redirect URI" {
        It "replaces the placeholder with the real Static Web App URL" {
            $App = New-FakeApplication -Properties @{ spa = @{ redirectUris = @("https://localhost") } }
            $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal -PortalRedirectUri "https://ci.azurestaticapps.net"

            $Patch.Body.spa.redirectUris | Should -Be @("https://ci.azurestaticapps.net")
            $Patch.Changes | Should -Contain "Removed placeholder SPA redirect URI https://localhost"
            $Patch.Changes | Should -Contain "Added SPA redirect URI https://ci.azurestaticapps.net"
        }

        It "never puts the placeholder back next to a real URI on a later run" {
            $App = New-FakeApplication -Properties @{ spa = @{ redirectUris = @("https://ci.azurestaticapps.net") } }
            $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal

            $Patch.Body.ContainsKey("spa") | Should -BeFalse
        }

        It "keeps other redirect URIs the administrator added" {
            $App = New-FakeApplication -Properties @{ spa = @{ redirectUris = @("https://localhost", "https://custom.contoso.com") } }
            $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal -PortalRedirectUri "https://ci.azurestaticapps.net"

            $Patch.Body.spa.redirectUris | Should -Be @("https://custom.contoso.com", "https://ci.azurestaticapps.net")
        }

        It "warns about, but does not remove, a Mobile and desktop platform on the Portal" {
            $App = New-FakeApplication -Properties @{ publicClient = @{ redirectUris = @("http://localhost") } }
            $Patch = Get-AppRegistrationPatch -Application $App -Spec $Spec.Portal -Kind Portal

            $Patch.Warnings | Should -HaveCount 1
            $Patch.Warnings[0] | Should -Match "AADSTS9002326"
            $Patch.Body.ContainsKey("publicClient") | Should -BeFalse
        }
    }
}

Describe "Invoke-WithRetry" {
    BeforeEach {
        Mock Start-Sleep { }
    }

    It "retries until the call succeeds" {
        $script:Calls = 0
        $Result = Invoke-WithRetry -ScriptBlock { $script:Calls++; if ($script:Calls -lt 3) { throw "not yet" }; "done" }
        $Result | Should -Be "done"
        $script:Calls | Should -Be 3
    }

    It "rethrows after the last attempt" {
        { Invoke-WithRetry -MaxAttempts 2 -ScriptBlock { throw "still failing" } } | Should -Throw "still failing"
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }
}

Describe "Get-ApplicationByDisplayName" {
    It "refuses to pick one of several registrations with the same name" {
        Mock Get-MgApplication { @((New-FakeApplication), (New-FakeApplication)) }
        { Get-ApplicationByDisplayName -DisplayName "Cloud Imaging Portal" } | Should -Throw "*Found 2 app registrations*"
    }

    It "escapes quotes in the OData filter" {
        Mock Get-MgApplication { } -ParameterFilter { $Filter -eq "displayName eq 'O''Brien Portal'" }
        Get-ApplicationByDisplayName -DisplayName "O'Brien Portal" | Should -BeNullOrEmpty
        Should -Invoke Get-MgApplication -Times 1 -Exactly
    }
}

Describe "new-app-registrations.ps1 against a fake tenant" {
    BeforeEach {
        # The fake tenant: app registrations by object ID (camelCase, as Graph stores them),
        # service principals, and oauth2PermissionGrants. Global, because the mocks run from
        # inside the script under test, where $script: is that script's own scope.
        $global:FakeTenant = @{ Apps = [ordered]@{}; ServicePrincipals = @(); Grants = @() }

        Mock Assert-GraphModule { }
        Mock Start-Sleep { }
        Mock Write-Host { }
        Mock Get-MgContext { [PSCustomObject]@{ TenantId = "tenant-1"; Account = "admin@contoso.com"; Scopes = @("Application.ReadWrite.All", "DelegatedPermissionGrant.ReadWrite.All") } }
        Mock Connect-MgGraph { }

        Mock Get-MgApplication {
            if ($ApplicationId) { return ConvertTo-GraphObject $global:FakeTenant.Apps[$ApplicationId] }
            $Name = ([regex]::Match($Filter, "displayName eq '(.*)'$").Groups[1].Value).Replace("''", "'")
            $global:FakeTenant.Apps.Values | Where-Object { $PSItem.displayName -eq $Name } | ForEach-Object { ConvertTo-GraphObject $PSItem }
        }
        Mock New-MgApplication {
            $Id = [guid]::NewGuid().ToString()
            $global:FakeTenant.Apps[$Id] = @{
                id = $Id; appId = [guid]::NewGuid().ToString(); displayName = $BodyParameter.displayName
                signInAudience = $BodyParameter.signInAudience; identifierUris = @(); appRoles = @()
                api = @{ oauth2PermissionScopes = @() }; spa = @{ redirectUris = @() }
                publicClient = @{ redirectUris = @() }; requiredResourceAccess = @()
            }
            ConvertTo-GraphObject $global:FakeTenant.Apps[$Id]
        }
        Mock Update-MgApplication {
            foreach ($Key in $BodyParameter.Keys) { $global:FakeTenant.Apps[$ApplicationId][$Key] = $BodyParameter[$Key] }
        }
        Mock Get-MgServicePrincipal {
            $AppId = [regex]::Match($Filter, "appId eq '(.*)'").Groups[1].Value
            $global:FakeTenant.ServicePrincipals | Where-Object { $PSItem.AppId -eq $AppId }
        }
        Mock New-MgServicePrincipal {
            $Sp = [PSCustomObject]@{ Id = [guid]::NewGuid().ToString(); AppId = $BodyParameter.appId }
            $global:FakeTenant.ServicePrincipals += $Sp
            $Sp
        }
        Mock Invoke-MgGraphRequest {
            switch ($Method) {
                "GET" { @{ value = @($global:FakeTenant.Grants) } }
                "POST" { $global:FakeTenant.Grants += ($Body | ConvertFrom-Json -AsHashtable) + @{ id = "grant-1" } }
                "PATCH" { ($global:FakeTenant.Grants | Where-Object { $PSItem.id -eq ($Uri -split "/")[-1] }).scope = ($Body | ConvertFrom-Json).scope }
            }
        }
    }

    AfterAll {
        Remove-Variable -Name FakeTenant -Scope Global -ErrorAction SilentlyContinue
    }

    It "creates all three registrations, their enterprise apps and the admin consent" {
        $Result = & $ScriptPath -TenantId "tenant-1"

        $global:FakeTenant.Apps.Count | Should -Be 3
        $global:FakeTenant.ServicePrincipals.Count | Should -Be 3
        $Portal = $global:FakeTenant.Apps.Values | Where-Object displayName -eq "Cloud Imaging Portal"
        $Operator = $global:FakeTenant.Apps.Values | Where-Object displayName -eq "Cloud Imaging Operator API"
        $MediaBuilder = $global:FakeTenant.Apps.Values | Where-Object displayName -eq "Cloud Imaging Media Builder"

        $Result.PortalClientId | Should -Be $Portal.appId
        $Result.OperatorApiClientId | Should -Be $Operator.appId
        $Result.MediaBuilderClientId | Should -Be $MediaBuilder.appId
        $Result.TenantId | Should -Be "tenant-1"

        $Operator.identifierUris | Should -Be @("api://$($Operator.appId)")
        $Portal.spa.redirectUris | Should -Be @("https://localhost")
        $MediaBuilder.publicClient.redirectUris | Should -Be @("http://localhost")

        # The Media Builder's permission points at the Operator API scope that was just created.
        $OperatorScopeId = $Operator.api.oauth2PermissionScopes[0].id
        $MediaBuilder.requiredResourceAccess[0].resourceAppId | Should -Be $Operator.appId
        $MediaBuilder.requiredResourceAccess[0].resourceAccess[0].id | Should -Be $OperatorScopeId

        $MediaBuilderSp = $global:FakeTenant.ServicePrincipals | Where-Object AppId -eq $MediaBuilder.appId
        $OperatorSp = $global:FakeTenant.ServicePrincipals | Where-Object AppId -eq $Operator.appId
        $global:FakeTenant.Grants | Should -HaveCount 1
        $global:FakeTenant.Grants[0].clientId | Should -Be $MediaBuilderSp.Id
        $global:FakeTenant.Grants[0].resourceId | Should -Be $OperatorSp.Id
        $global:FakeTenant.Grants[0].consentType | Should -Be "AllPrincipals"
        $global:FakeTenant.Grants[0].scope | Should -Be "user_impersonation"
    }

    It "changes nothing when run a second time" {
        & $ScriptPath | Out-Null
        $Before = $global:FakeTenant.Apps | ConvertTo-Json -Depth 10

        $Result = & $ScriptPath

        Should -Invoke New-MgApplication -Times 3 -Exactly
        Should -Invoke New-MgServicePrincipal -Times 3 -Exactly
        Should -Invoke Update-MgApplication -Times 3 -Exactly
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $Method -ne "GET" } -Times 1 -Exactly
        ($global:FakeTenant.Apps | ConvertTo-Json -Depth 10) | Should -Be $Before
        $Result.PortalClientId | Should -Not -BeNullOrEmpty
    }

    It "swaps in the Static Web App URL on a re-run after deployment" {
        & $ScriptPath | Out-Null
        & $ScriptPath -PortalRedirectUri "https://ci-prod.azurestaticapps.net" | Out-Null

        ($global:FakeTenant.Apps.Values | Where-Object displayName -eq "Cloud Imaging Portal").spa.redirectUris | Should -Be @("https://ci-prod.azurestaticapps.net")
    }

    It "adds user_impersonation to an existing consent grant instead of creating a second one" {
        & $ScriptPath -SkipAdminConsent | Out-Null
        $MediaBuilder = $global:FakeTenant.Apps.Values | Where-Object displayName -eq "Cloud Imaging Media Builder"
        $Operator = $global:FakeTenant.Apps.Values | Where-Object displayName -eq "Cloud Imaging Operator API"
        $global:FakeTenant.Grants = @(@{
                id          = "existing"
                clientId    = ($global:FakeTenant.ServicePrincipals | Where-Object AppId -eq $MediaBuilder.appId).Id
                resourceId  = ($global:FakeTenant.ServicePrincipals | Where-Object AppId -eq $Operator.appId).Id
                consentType = "AllPrincipals"
                scope       = "other.scope"
            })

        & $ScriptPath | Out-Null

        $global:FakeTenant.Grants | Should -HaveCount 1
        $global:FakeTenant.Grants[0].scope | Should -Be "other.scope user_impersonation"
    }

    It "skips the consent grant with -SkipAdminConsent and does not ask for the consent scope" {
        Mock Get-MgContext { $null }

        & $ScriptPath -SkipAdminConsent | Out-Null

        $global:FakeTenant.Grants | Should -HaveCount 0
        Should -Invoke Connect-MgGraph -ParameterFilter { $Scopes -notcontains "DelegatedPermissionGrant.ReadWrite.All" } -Times 1 -Exactly
    }

    It "makes no changes with -WhatIf" {
        & $ScriptPath -WhatIf | Out-Null

        $global:FakeTenant.Apps.Count | Should -Be 0
        Should -Invoke New-MgApplication -Times 0 -Exactly
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $Method -ne "GET" } -Times 0 -Exactly
    }

    It "carries on with the other registrations when one fails, and reports the failure" {
        Mock New-MgApplication { throw "Insufficient privileges" } -ParameterFilter { $BodyParameter.displayName -eq "Cloud Imaging Portal" }

        $Result = & $ScriptPath 3>&1 | Where-Object { $PSItem -isnot [System.Management.Automation.WarningRecord] }

        $global:FakeTenant.Apps.Count | Should -Be 2
        $Result.PortalClientId | Should -BeNullOrEmpty
        $Result.OperatorApiClientId | Should -Not -BeNullOrEmpty
        $global:FakeTenant.Grants | Should -HaveCount 1
    }
}
