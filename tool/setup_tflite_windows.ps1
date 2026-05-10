$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$blobsDir = Join-Path $repoRoot 'blobs'
$zipPath = Join-Path $env:TEMP 'tflite_c_v2.17.1_windows_amd64.zip'
$extractDir = Join-Path $env:TEMP 'tflite_c_v2.17.1_windows_amd64'
$downloadUrl = 'https://github.com/tphakala/tflite_c/releases/download/v2.17.1/tflite_c_v2.17.1_windows_amd64.zip'

New-Item -ItemType Directory -Force -Path $blobsDir | Out-Null
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath

if (Test-Path $extractDir) {
  Remove-Item -LiteralPath $extractDir -Recurse -Force
}
Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

$sourceDll = Get-ChildItem -Path $extractDir -Recurse -File -Filter '*tensorflowlite*c*.dll' |
  Select-Object -First 1
if ($null -eq $sourceDll) {
  throw 'No TensorFlow Lite C DLL found in downloaded archive.'
}

$repoDll = Join-Path $blobsDir 'libtensorflowlite_c-win.dll'
Copy-Item -LiteralPath $sourceDll.FullName -Destination $repoDll -Force

$flutterExe = (Get-Command flutter).Source
$engineBlobs = Join-Path (Split-Path $flutterExe -Parent) 'cache\artifacts\engine\windows-x64\blobs'
New-Item -ItemType Directory -Force -Path $engineBlobs | Out-Null
Copy-Item -LiteralPath $repoDll -Destination (Join-Path $engineBlobs 'libtensorflowlite_c-win.dll') -Force

Get-Item $repoDll, (Join-Path $engineBlobs 'libtensorflowlite_c-win.dll') |
  Select-Object FullName, Length
