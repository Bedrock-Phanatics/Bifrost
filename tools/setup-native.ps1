# Builds the patched libdatachannel that nethernet-zig needs into .deps/native
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

$pin = Select-String -Path build.zig.zon -Pattern 'nethernet-zig#([0-9a-f]{40})'
if (!$pin) { throw 'build.zig.zon has no nethernet-zig commit' }
$commit = $pin.Matches[0].Groups[1].Value
New-Item -ItemType Directory -Force .deps | Out-Null

if (!(Test-Path -LiteralPath .deps/nethernet-zig/.git)) {
    git clone https://github.com/Bedrock-Phanatics/nethernet-zig.git .deps/nethernet-zig
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
}
git -C .deps/nethernet-zig fetch --quiet origin
git -C .deps/nethernet-zig checkout --quiet $commit
if ($LASTEXITCODE -ne 0) { throw "can't check out nethernet-zig $commit" }

& .deps/nethernet-zig/tools/setup-native.ps1 @args
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .deps/native
Copy-Item -Recurse .deps/nethernet-zig/.deps/native .deps/native
