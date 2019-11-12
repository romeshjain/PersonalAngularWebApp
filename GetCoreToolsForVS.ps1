$ErrorActionPreference = "Stop"

if (-Not (Get-Module -ListAvailable -Name BitsTransfer)) {
    Import-Module BitsTransfer
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Unzip([string]$zipfilePath, [string]$outputpath) {
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfilePath, $outputpath)
    }
    catch {
        LogErrorAndExit "Unzip failed for:$zipfilePath" $_.Exception
    }
}

function Download($url, $filePath)  
{
    try {
    $jobs = Start-BitsTransfer -source $url -destination $filePath
    }
    catch {
        LogErrorAndExit "Download failed:$url" $_.Exception
    }
}

function DownloadRelease($releaseInfo, $releaseDir)
{
    $cli = $releaseInfo.cli
    Download $cli "$releaseDir\cli.zip"

    $itemTemplates = $releaseInfo.itemTemplates
    Invoke-WebRequest -Uri $itemTemplates -OutFile "$releaseDir\ItemTemplates.nupkg"

    $projectTemplates = $releaseInfo.projectTemplates
    Invoke-WebRequest -Uri $projectTemplates  -OutFile "$releaseDir\ProjectTemplates.nupkg"
}

function LogOperationStart($message) {
    Write-Host $message -NoNewline
}

function LogSuccess($message) {
    Write-Host -ForegroundColor Green "...Done"
}

function LogErrorAndExit($errorMessage, $exception) {
    Write-Host -ForegroundColor Red "...Failed" 
    Write-Host $errorMessage -ForegroundColor Red
    if ($exception -ne $null) {
        Write-Host $exception -ForegroundColor Red | format-list -force
    }    
    Exit
}

function GetRelease($response, $release)
{
    try {
        LogOperationStart "Creating temporary download directories" 
        $Guid = New-Guid 
        $tempDownload = $Env:Temp + "\" +  $Guid.Guid.ToString()
        $releaseVersion = $response.tags.$release.release
        $tempReleaseDir = $tempDownload + "\" + $releaseVersion
        $dir = New-Item -Path $tempDownload -ItemType Directory
        $dir = New-Item -Path $tempReleaseDir -ItemType Directory
        LogSuccess
    }
    catch {
        LogErrorAndExit "Unable to create temporary download directories" $_.Exception
    }

    try {
        $releaseInfo = $response.releases."$releaseVersion"
        DownloadRelease $releaseInfo $tempReleaseDir
    }
    catch {
        LogErrorAndExit "Error Downloading release" $_.Exception
    }

    try {
        LogOperationStart "Creating release directory"
        $releaseDir = $Env:userProfile + "\AppData\local\AzureFunctionsTools\Releases\" + $releaseVersion 
        if (-Not (Test-Path $releaseDir)) {
            $dir = New-Item -ItemType Directory $releaseDir
        }

        $releaseCliDir = $releaseDir + "\cli"
        if (-Not (Test-Path $releaseCliDir)) {
            $dir = New-Item -ItemType Directory $releaseCliDir
        }

        $templatesDir = $releaseDir + "\templates"
        if (-Not (Test-Path $templatesDir)) {
            $dir = New-Item -ItemType Directory $templatesDir
        }

        LogSuccess
    }
    catch {
        LogErrorAndExit "Error creating release directory" $_.Exception
    }

    try {
        $cliZip = "$tempReleaseDir\cli.zip"
        LogOperationStart "Unzipping $cliZip to $releaseCliDir"

        if (Test-Path $releaseCliDir) {
            Remove-Item -Path $releaseCliDir -Recurse
        }

        Unzip $cliZip $releaseCliDir
        LogSuccess

        LogOperationStart "Copying $tempReleaseDir\ItemTemplates.nupkg to $templatesDir"
        Copy-Item "$tempReleaseDir\ItemTemplates.nupkg" $templatesDir -Force
        LogSuccess

        LogOperationStart "Copying $tempReleaseDir\ProjectTemplates.nupkg to $templatesDir"
        Copy-Item "$tempReleaseDir\ProjectTemplates.nupkg" $templatesDir -Force
        LogSuccess
    }
    catch {
        LogErrorAndExit "Error copying artifacts" $_.Exception
    }
}

function GenerateManifestFile($response, $release)
{
    try {
    LogOperationStart "Generating Manifest file for $release" 
    $releaseVersion = $response.tags.$release.release
    $releaseInfo = $response.releases.$releaseVersion
    $cliEntrypointPath = $Env:userProfile + "\AppData\Local\AzureFunctionsTools\Releases\" + $releaseVersion + "\cli\" + $releaseInfo.localEntryPoint
    $templatesDirectory = $Env:userProfile + "\AppData\Local\AzureFunctionsTools\Releases\" + $releaseVersion + "\templates"

    if ($release -eq "v1") 
    {
        $minRuntimeVersion = $null
        $requiredRuntime = $null
    }
    else 
    {
        $minRuntimeVersion = $releaseInfo.minimumRuntimeVersion
        $requiredRuntime = $releaseInfo.requiredRuntime
    }

    $extVersion = $releaseInfo.FUNCTIONS_EXTENSION_VERSION
    $packageVersion = $releaseInfo.'Microsoft.NET.Sdk.Functions'
    
    $json = @{
            CliEntrypointPath =  $cliEntrypointPath
            FunctionsExtensionVersion = $extVersion
            MinimumRuntimeVersion = $minRuntimeVersion
            ReleaseName = $extVersion
            RequiredRuntime = $requiredRuntime
            SdkPackageVersion = $packageVersion
            TemplatesDirectory = $templatesDirectory
    }
    
    $manifestFile = $Env:userProfile + "\AppData\Local\AzureFunctionsTools\Releases\" + $releaseVersion + "\manifest.json"
    $json | ConvertTo-Json | Out-File -FilePath $manifestFile

    LogSuccess
    }
    catch {
        LogErrorAndExit "Error generating manifest file for $release" $_.Exception
    }
}
# Starting the script here
try {
    LogOperationStart "Determining the latest version of Azure Function Core Tools"
    $url = "https://functionscdn.azureedge.net/public/cli-feed-v3.json"
    $response = Invoke-RestMethod -Uri $url -Method GET 
    LogSuccess
}
catch {
    LogErrorAndExit "Unable to get the latest Core Tools version information" $_.Exception
}

Write-Host "Downloading v1 release artifacts" -ForegroundColor Yellow
GetRelease $response v1
GenerateManifestFile $response v1
Write-Host "Downloading v1 release artifacts...Complete" -ForegroundColor Yellow

Write-Host "Downloading v2 release artifacts" -ForegroundColor Yellow
GetRelease $response v2
GenerateManifestFile $response v2
Write-Host "Downloading v2 release artifacts...Complete" -ForegroundColor Yellow

try {
    LogOperationStart "Deleting template cache"
    $templateCache = $Env:userProfile + "\.templateEngine" 
    
    if (Test-Path $templateCache) {
        Remove-Item -Path $templateCache -Recurse
    }
    LogSuccess
} 
catch {
    LogErrorAndExit "Error Deleting template cache" $_.Exception
}

try {
    LogOperationStart "Setting up Core Tools Metadata"

    $feedFile = "$Env:userProfile\AppData\local\AzureFunctionsTools\feed.json"
    
    if (Test-Path $feedFile) {
        Remove-Item -Path  $feedFile -Force
    }

    $response = Invoke-RestMethod -Uri $url -Method GET -OutFile "$Env:userProfile\AppData\local\AzureFunctionsTools\feed.json"

    $v1TagsDirectory = $Env:userProfile + "\AppData\Local\AzureFunctionsTools\Tags\v1"
    $v2TagsDirectory = $Env:userProfile + "\AppData\Local\AzureFunctionsTools\Tags\v2"

    $v1TagsFile = "$v1TagsDirectory\LastKnownGood" 
    $v2TagsFile = "$v2TagsDirectory\LastKnownGood" 

    if (-Not (Test-Path $v1TagsDirectory)) {
        $dir = New-Item -ItemType Directory $v1TagsDirectory
    }

    if (-Not (Test-Path $v2TagsDirectory)) {
        $dir = New-Item -ItemType Directory $v2TagsDirectory
    }

    if (Test-Path $v1TagsFile) {
        Remove-Item -Path $v1TagsFile
    }

    if (Test-Path $v2TagsFile) {
        Remove-Item -Path $v2TagsFile
    }

    Write-Output $response.tags.v1.release | Out-File -FilePath $v1TagsFile
    Write-Output $response.tags.v2.release | Out-File -FilePath $v2TagsFile

    LogSuccess
} 
catch {
    LogErrorAndExit "Error Setting up Core Tools Metadata" $_.Exception
}
