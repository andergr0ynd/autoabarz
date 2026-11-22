param([string]$MoonloaderPath = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$moonloader = (Resolve-Path -LiteralPath $MoonloaderPath).Path
$scriptPath = Join-Path $moonloader '#ArzMarket[3_57].lua'
$bridgePath = Join-Path $moonloader 'lib/abarz-market-bridge.lua'
if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
    throw 'Copy lib/abarz-market-bridge.lua into the game moonloader folder first.'
}
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw 'ArzMarket 3.57 was not found. Pass -MoonloaderPath with the game moonloader folder.'
}
$bytes = [IO.File]::ReadAllBytes($scriptPath)
$text = [Text.Encoding]::UTF8.GetString($bytes)
if ($text.StartsWith('-- Local ABarz price bridge;')) {
    Write-Host 'ABarz bridge is already installed.'
    exit 0
}
if ($bytes.Length -lt 3 -or $bytes[0] -ne 27 -or $bytes[1] -ne 76 -or $bytes[2] -ne 74) {
    throw 'Expected original LuaJIT bytecode. Nothing was replaced.'
}
$backupDir = Join-Path $moonloader 'ArzMarket/abarz-bridge'
$backupPath = Join-Path $backupDir 'original-3.57.luac'
[IO.Directory]::CreateDirectory($backupDir) | Out-Null
if (Test-Path -LiteralPath $backupPath) {
    $old = [IO.File]::ReadAllBytes($backupPath)
    if ([Convert]::ToBase64String($old) -ne [Convert]::ToBase64String($bytes)) {
        throw 'A different original backup already exists. Nothing was replaced.'
    }
} else {
    [IO.File]::WriteAllBytes($backupPath, $bytes)
}
$wrapper = @'
-- Local ABarz price bridge; original Arizona Market bytecode is preserved.
local path=getWorkingDirectory()..'/ArzMarket/abarz-bridge/original-3.57.luac'
local original,why=loadfile(path)
if not original then error('ABarz bridge: '..tostring(why)) end
local ok,bridge=pcall(dofile,getWorkingDirectory()..'/lib/abarz-market-bridge.lua')
if ok then
    local installed,reason=pcall(bridge.install)
    if not installed then print('ABarz price bridge unavailable: '..tostring(reason)) end
else print('ABarz price bridge unavailable: '..tostring(bridge)) end
return original()
'@
[IO.File]::WriteAllText($scriptPath, $wrapper, (New-Object Text.UTF8Encoding($false)))
Write-Host 'Bridge installed. Original preserved in ArzMarket/abarz-bridge/original-3.57.luac.'
Write-Host 'Reload ArzMarket, open /crr, and select Vice City.'
