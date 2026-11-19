@{
    RootModule        = 'PwManager.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '67758978-7d08-419a-a448-af502dfd98f4'
    Author            = 'yura'
    Description       = 'SecretManagement / SecretStore を使ったローカルパスワード管理ツール'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Show-PwManager'
        'Get-PwEntry'
        'Copy-PwField'
        'New-PwPassword'
        'Backup-PwVault'
        'Restore-PwVault'
        'Import-PwCsv'
        'Export-PwCsv'
        'Edit-PwConfig'
        'Initialize-PwManager'
        'Install-PwShortcut'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('pwm')
}
