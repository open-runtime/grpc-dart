Describe "bootstrap-devbox -PlanOnly" {
    It "declares the required Windows host features" {
        $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "bootstrap-devbox.ps1"
        $plan = & $scriptPath -PlanOnly | ConvertFrom-Json
        $plan.workspaceRoot | Should -Be "C:\dev"
        $plan.features | Should -Contain "OpenSSH.Server~~~~0.0.1.0"
        $plan.packages | Should -Contain "Git.Git"
        $plan.packages | Should -Contain "Docker.DockerDesktop"
        $plan.sshdConfig.AllowTcpForwarding | Should -Be "yes"
    }
}
