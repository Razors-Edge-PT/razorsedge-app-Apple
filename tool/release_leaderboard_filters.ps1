# Fetch origin/main and create a fresh release branch in this worktree first.
# Run this from C:\Projects\goodlift_app\GoodLift_production in PowerShell.
# Uses the existing Firebase/ADC login and Android upload signing inputs.
# Richard uploads the resulting AAB to Play Internal Testing.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function Run-Step([scriptblock] $Action, [string] $Label) {
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)." }
}

$versionLine = Get-Content '.\pubspec.yaml' | Where-Object { $_ -match '^version:\s*' }
$version = ($versionLine -replace '^version:\s*', '').Trim()
if ($version -ne '1.7.54+124') { throw "Expected GoodLift 1.7.54+124; found $version. Review the newer release before running this script." }
$changes = git status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Git status.' }
if ($changes) { throw 'Commit or resolve your tracked local changes before making the release build. Nothing has been discarded.' }

Run-Step { flutter pub get } 'Flutter dependencies'
Run-Step { flutter analyze } 'Flutter analysis'
Run-Step { flutter test } 'Flutter tests'

Push-Location '.\functions'
try {
    Run-Step { npm ci } 'Functions dependencies'
    Run-Step { npm test } 'Functions unit tests'
    Run-Step { firebase emulators:exec --only firestore,auth,storage --project rules-test 'node --test --test-concurrency=1 test-rules/leaderboard_rules.spec.js' } 'Leaderboard access rules tests'
    Run-Step { npm run test:emulator } 'Functions emulator tests'
    # Only these two existing exports depend on the new public filter helper.
    & firebase deploy --only 'functions:leaderboardPublicPublisher,functions:publicLeaderboard' --project goodlift-us-storage
    $deployExit = $LASTEXITCODE
    # Preserve the existing anonymous website endpoint setting, including if
    # an organisation policy rejected Firebase's allUsers IAM-binding attempt.
    Run-Step { gcloud run services update publicleaderboard --project goodlift-us-storage --region us-central1 --no-invoker-iam-check } 'Public endpoint access'
    if ($deployExit -ne 0) { throw 'Firebase reported a deployment error. Review its output and rerun after correcting it; no AAB was built.' }
    Run-Step { node scripts/publish_leaderboard_filters.js --project goodlift-us-storage --apply } 'Initial filtered leaderboard publication'
    $source = 'https://us-central1-goodlift-us-storage.cloudfunctions.net/publicLeaderboard'
    foreach ($period in @('current', 'all_time')) {
        foreach ($view in @('raw', 'age')) {
            foreach ($sex in @('all', 'male', 'female')) {
                $feed = Invoke-RestMethod "$source`?period=$period&view=$view&sex=$sex"
                if ($sex -ne 'all' -and $feed.sexFilter -ne $sex) { throw "Wrong group returned for $period/$view/$sex." }
                if ($view -eq 'age' -and $feed.view -ne 'age') { throw 'Wrong score mode returned.' }
                Write-Host "$period / $view / $sex : $(@($feed.entries).Count) ranked athletes"
            }
        }
    }
}
finally { Pop-Location }

# Publish the tested website branch only after all backend combinations work.
# The existing Cloudflare Pages integration automatically deploys a main push.
$siteCheckout = Join-Path $env:TEMP ('GoodLift-sex-filter-site-' + [Guid]::NewGuid().ToString('N'))
Run-Step { git clone --branch codex/leaderboard-sex-filter-20261008 --single-branch 'https://github.com/Razors-Edge-PT/goodlift-website.git' $siteCheckout } 'Website release checkout'
Push-Location $siteCheckout
try {
    Run-Step { git fetch origin main } 'Website main fetch'
    Run-Step { git merge --ff-only FETCH_HEAD } 'Website source reconciliation'
    Run-Step { git push origin HEAD:main } 'Website main publication'
}
finally { Pop-Location }
$siteLive = $false
for ($attempt = 0; $attempt -lt 18; $attempt++) {
    try {
        $page = Invoke-WebRequest 'https://goodliftapp.com/leaderboard/' -UseBasicParsing
        $feed = Invoke-RestMethod 'https://goodliftapp.com/api/leaderboard?period=all_time&view=age&sex=female'
        if ($page.Content.Contains('data-board-sex-option="female"') -and $feed.sexFilter -eq 'female') {
            $siteLive = $true; break
        }
    }
    catch { Write-Host 'Waiting for the Cloudflare website deployment...' }
    Start-Sleep -Seconds 10
}
if (!$siteLive) { throw 'The website main push succeeded, but its deployment is not verified yet. Check Cloudflare Pages before proceeding.' }
Write-Host 'Website sex filter is live.'

$aab = '.\build\app\outputs\bundle\release\app-release.aab'
if (Test-Path $aab) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item $aab ".\build\app\outputs\bundle\release\app-release-before-sex-filter-$stamp.aab"
}
Run-Step { flutter build appbundle --release } 'Android release build'
if (!(Test-Path $aab)) { throw 'The expected AAB was not produced.' }
$finalChanges = git status --porcelain --untracked-files=no
if ($finalChanges) { throw 'The build changed tracked source files. Review them before uploading the AAB.' }
Run-Step { jarsigner -verify $aab } 'AAB signature verification'
Run-Step { keytool -printcert -jarfile $aab } 'Upload certificate inspection'
$versioned = ".\build\app\outputs\bundle\release\GoodLift-$version-release.aab"
Copy-Item $aab $versioned
Get-FileHash $versioned -Algorithm SHA256
Write-Host "Built: $((Resolve-Path $versioned).Path)"
Write-Host 'Confirm versionName 1.7.54 and versionCode 124 in Play before submitting to Internal Testing.'
