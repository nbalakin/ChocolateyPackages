﻿function Start-VisualStudioModifyOperation
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageName,
        [AllowEmptyCollection()] [AllowEmptyString()] [Parameter(Mandatory = $true)] [string[]] $ArgumentList,
        [Parameter(Mandatory = $true)] [string] $VisualStudioYear,
        [Parameter(Mandatory = $true)] [string[]] $ApplicableProducts,
        [Parameter(Mandatory = $true)] [string[]] $OperationTexts,
        [ValidateSet('modify', 'uninstall')] [string] $Operation = 'modify',
        [string] $InstallerPath
    )
    Write-Debug "Running 'Start-VisualStudioModifyOperation' with PackageName:'$PackageName' ArgumentList:'$ArgumentList' VisualStudioYear:'$VisualStudioYear' ApplicableProducts:'$ApplicableProducts' OperationTexts:'$OperationTexts' Operation:'$Operation' InstallerPath:'$InstallerPath'";

    $frobbed, $frobbing, $frobbage = $OperationTexts

    if ($InstallerPath -eq '')
    {
        $InstallerPath = Get-VSUninstallerExePath `
                            -PackageName $PackageName `
                            -UninstallerName 'vs_installer.exe' `
                            -ProgramsAndFeaturesDisplayName "Microsoft Visual Studio $VisualStudioYear" `
                            -AssumeNewVS2017Installer

        if ($InstallerPath -eq $null)
        {
            throw "Unable to determine the location of the Visual Studio Installer. Is Visual Studio $VisualStudioYear installed?"
        }
    }

    $packageParameters = Parse-Parameters $env:chocolateyPackageParameters

    for ($i = 0; $i -lt $ArgumentList.Length; $i += 2)
    {
        $packageParameters[$ArgumentList[$i]] = $ArgumentList[$i + 1]
    }

    $packageParameters['norestart'] = ''
    if (-not $packageParameters.ContainsKey('quiet') -and -not $packageParameters.ContainsKey('passive'))
    {
        $packageParameters['quiet'] = ''
    }

    # --no-foo cancels --foo
    $negativeSwitches = $packageParameters.GetEnumerator() | Where-Object { $_.Key -match '^no-.' -and $_.Value -eq '' } | Select-Object -ExpandProperty Key
    foreach ($negativeSwitch in $negativeSwitches)
    {
        if ($negativeSwitch -eq $null)
        {
            continue
        }

        $packageParameters.Remove($negativeSwitch.Substring(3))
        $packageParameters.Remove($negativeSwitch)
    }

    $argumentSets = ,$packageParameters
    if ($packageParameters.ContainsKey('installPath'))
    {
        if ($packageParameters.ContainsKey('productId'))
        {
            Write-Warning 'Parameter issue: productId is ignored when installPath is specified.'
        }

        if ($packageParameters.ContainsKey('channelId'))
        {
            Write-Warning 'Parameter issue: channelId is ignored when installPath is specified.'
        }
    }
    elseif ($packageParameters.ContainsKey('productId'))
    {
        if (-not $packageParameters.ContainsKey('channelId'))
        {
            throw "Parameter error: when productId is specified, channelId must be specified, too."
        }
    }
    elseif ($packageParameters.ContainsKey('channelId'))
    {
        throw "Parameter error: when channelId is specified, productId must be specified, too."
    }
    else
    {
        $installedProducts = Get-WillowInstalledProducts -VisualStudioYear $VisualStudioYear
        if (($installedProducts | Measure-Object).Count -eq 0)
        {
            throw "Unable to detect any supported Visual Studio $VisualStudioYear product. You may try passing --installPath or both --productId and --channelId parameters."
        }

        if ($Operation -eq 'modify')
        {
            if ($packageParameters.ContainsKey('add'))
            {
                $packageIdsList = $packageParameters['add']
                $unwantedPackageSelector = { $productInfo.selectedPackages.ContainsKey($_) }
                $unwantedStateDescription = 'contains'
            }
            elseif ($packageParameters.ContainsKey('remove'))
            {
                $packageIdsList = $packageParameters['remove']
                $unwantedPackageSelector = { -not $productInfo.selectedPackages.ContainsKey($_) }
                $unwantedStateDescription = 'does not contain'
            }
            else
            {
                throw "Unsupported scenario: neither 'add' nor 'remove' is present in parameters collection"
            }
        }
        elseif ($Operation -eq 'uninstall')
        {
            $packageIdsList = ''
            $unwantedPackageSelector = { $false }
            $unwantedStateDescription = '<unused>'
        }
        else
        {
            throw "Unsupported Operation: $Operation"
        }

        $packageIds = ($packageIdsList -split ' ') | ForEach-Object { $_ -split ';' | Select-Object -First 1 }
        $applicableProductIds = $ApplicableProducts | ForEach-Object { "Microsoft.VisualStudio.Product.$_" }
        Write-Debug ('This package supports Visual Studio product id(s): {0}' -f ($applicableProductIds -join ' '))

        $argumentSets = @()
        foreach ($productInfo in $installedProducts)
        {
            $applicable = $false
            $thisProductIds = $productInfo.selectedPackages.Keys | Where-Object { $_ -like 'Microsoft.VisualStudio.Product.*' }
            Write-Debug ('Product at path ''{0}'' has product id(s): {1}' -f $productInfo.installationPath, ($thisProductIds -join ' '))
            foreach ($thisProductId in $thisProductIds)
            {
                if ($applicableProductIds -contains $thisProductId)
                {
                    $applicable = $true
                }
            }

            if (-not $applicable)
            {
                Write-Verbose ('Product at path ''{0}'' will not be modified because it does not support package(s): {1}' -f $productInfo.installationPath, $packageIds)
                continue
            }

            $unwantedPackages = $packageIds | Where-Object $unwantedPackageSelector
            if (($unwantedPackages | Measure-Object).Count -gt 0)
            {
                Write-Verbose ('Product at path ''{0}'' will not be modified because it already {1} package(s): {2}' -f $productInfo.installationPath, $unwantedStateDescription, ($unwantedPackages -join ' '))
                continue
            }

            $argumentSet = $packageParameters.Clone()
            $argumentSet['installPath'] = $productInfo.installationPath
            $argumentSets += $argumentSet
        }
    }

    $overallExitCode = 0
    foreach ($argumentSet in $argumentSets)
    {
        if ($argumentSet.ContainsKey('installPath'))
        {
            Write-Debug "Modifying Visual Studio product: [installPath = '$($argumentSet.installPath)']"
        }
        else
        {
            Write-Debug "Modifying Visual Studio product: [productId = '$($argumentSet.productId)' channelId = '$($argumentSet.channelId)']"
        }

        foreach ($kvp in $argumentSet.Clone().GetEnumerator())
        {
            if ($kvp.Value -match '^(([^"].*\s)|(\s))')
            {
                $argumentSet[$kvp.Key] = '"{0}"' -f $kvp.Value
            }
        }

        $silentArgs = $Operation + (($argumentSet.GetEnumerator() | ForEach-Object { ' --{0} {1}' -f $_.Key, $_.Value }) -join '')
        $exitCode = -1
        if ($PSCmdlet.ShouldProcess("Executable: $InstallerPath", "Start with arguments: $silentArgs"))
        {
            $exitCode = Start-VSChocolateyProcessAsAdmin -statements $silentArgs -exeToRun $InstallerPath -validExitCodes @(0, 3010)
        }

        if ($overallExitCode -eq 0)
        {
            $overallExitCode = $exitCode
        }
    }

    $Env:ChocolateyExitCode = $overallExitCode
    if ($overallExitCode -eq 3010)
    {
        Write-Warning "${PackageName} has been ${frobbed}. However, a reboot is required to finalize the ${frobbage}."
    }
}
