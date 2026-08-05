# PSScriptAnalyzer 配置（CI 使用）
# 仅 Error 级会阻断构建；Warning 级在 CI 中仅打印提示、不失败。
# IncludeRules 已限定为功能型规则，纯风格类（命名、空白、对齐等）不在其中，本就不参与检查。
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
