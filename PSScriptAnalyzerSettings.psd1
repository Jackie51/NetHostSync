# PSScriptAnalyzer 配置（CI 使用）
# 仅对「错误 / 警告」级规则失败；纯风格类（命名、空白等）仅作为信息，不阻断构建。
@{
    IncludeRules = @(
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingDeprecatedManifestFields',
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidGlobalVars',
        'PSAvoidUninitializedVariable',
        'PSAvoidUsingPositionalParameters',
        'PSReservedParams',
        'PSPossibleIncorrectComparisonWithNull',
        'PSUseApprovedVerbs',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Severity = @('Error', 'Warning')
    ExcludeRules = @()
    RecurseCustomRulePath = $false
}
