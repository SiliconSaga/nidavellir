# test.ps1
# Runs Kuttl tests using Docker on Windows against a local cluster (Rancher Desktop/k3d).
# Adapted from mimir/test.ps1; runs the platform suite (kuttl-test.yaml) by default.
# -Config selects another suite, typically with a --test filter to skip the
# domain-dependent whoami case:
#   ./test.ps1 -Config kuttl-test-e2e.yaml --test keycloak
param([string]$Config = "kuttl-test.yaml")

$ErrorActionPreference = "Stop"

# Normalize -Config: Windows-style backslashes would reach the Linux
# container literally and break the copy, and a leading ./ is noise.
# The charset check then keeps shell metacharacters out of the sh -c
# interpolation below (also makes the value injection-safe — though the
# only "attacker" here is the developer running their own wrapper).
$Config = ($Config -replace '\\', '/') -replace '^\./', ''
if ($Config -notmatch '^[A-Za-z0-9._/-]+$') {
    throw "-Config must be a plain repo-relative file name (got: $Config)"
}

# Pinned by digest: the upstream repo stopped tagging versions at v0.15.0 while
# `latest` carries the modern kuttl (v0.24-era assertion semantics this suite
# is written against). Digest = the `latest` validated 2026-06-10.
$KuttlImage = "kudobuilder/kuttl@sha256:d23368441f313107954e80a3a5f2884f374bd5a4746193e304c7733f98d6915e"

# Create a temporary kubeconfig file
$TempKubeConfig = [System.IO.Path]::GetTempFileName()

try {
    Write-Host "Preparing kubeconfig for Docker..." -ForegroundColor Cyan

    # Flatten the current kubeconfig and save to temp file
    # We use --minify to only get the current context
    kubectl config view --minify --flatten | Out-File -FilePath $TempKubeConfig -Encoding UTF8

    # Read the file content
    $Content = Get-Content -Path $TempKubeConfig -Raw

    # Replace localhost/127.0.0.1 with host.docker.internal
    $Content = $Content -replace '127\.0\.0\.1', 'host.docker.internal'
    $Content = $Content -replace 'localhost', 'host.docker.internal'

    # Remove certificate-authority-data (since we are changing the host, the cert won't match usually if it's IP based,
    # and often local clusters use self-signed certs that Docker container won't trust)
    $Content = $Content -replace 'certificate-authority-data:.*', 'insecure-skip-tls-verify: true'

    # Save back to temp file
    $Content | Set-Content -Path $TempKubeConfig -Encoding UTF8

    Write-Host "Running Kuttl via Docker..." -ForegroundColor Cyan

    $RepoRoot = Get-Location
    # The auto-detect dir must match the suite the chosen config runs:
    # kuttl-test.yaml → tests\platform, kuttl-test-e2e.yaml → tests\e2e.
    $TestDir = if ($Config -match 'e2e') { Join-Path $RepoRoot "tests\e2e" } else { Join-Path $RepoRoot "tests\platform" }

    # Smart argument handling
    $DockerArgs = @()
    $PrevArg = ""
    foreach ($arg in $args) {
        if ($arg -notmatch "^-") {
            # Normalize backslashes up front so suite names/paths survive the
            # trip into the Linux container regardless of how they were typed.
            $arg = $arg -replace '\\', '/'

            # If previous arg was --test, this is already its value — pass through as-is
            if ($PrevArg -eq "--test") {
                $DockerArgs += $arg
                $PrevArg = $arg
                continue
            }

            # Check if it's a known test suite name (bare name without --test)
            $PotentialTestPath = Join-Path $TestDir $arg
            if (Test-Path $PotentialTestPath) {
                Write-Host "  Auto-detecting test suite: $arg -> --test $arg" -ForegroundColor Yellow
                $DockerArgs += "--test"
                $DockerArgs += $arg
                $PrevArg = $arg
                continue
            }
        }
        $DockerArgs += $arg
        $PrevArg = $arg
    }

    # Run Docker container
    # We map the temp Kubeconfig to /kubeconfig
    # We map the repo root to /workspace
    # To avoid polluting the host with a 'kubectl' symlink, we work in /tmp inside the container
    docker run --rm `
        -v "${TempKubeConfig}:/kubeconfig" `
        -v "${RepoRoot}:/workspace" `
        -e KUBECONFIG=/kubeconfig `
        --add-host host.docker.internal:host-gateway `
        --entrypoint /bin/sh `
        $KuttlImage `
        -c "mkdir -p /tmp/work && cp /workspace/$Config /tmp/work/ && ln -s /workspace/tests /tmp/work/tests && ln -s /usr/bin/kubectl /tmp/work/kubectl && cd /tmp/work && kubectl-kuttl test --config $Config $DockerArgs"
}
finally {
    # The temp kubeconfig carries cluster credentials — always clean it up,
    # even when kubectl or docker fail above.
    Remove-Item -Path $TempKubeConfig -ErrorAction SilentlyContinue
}
