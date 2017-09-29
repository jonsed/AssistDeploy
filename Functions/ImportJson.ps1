function Import-Json {
    <#
.Synopsis
Import the integration services catalog publish json file
.Description
Internal function used to import the json file that stores the integration services catalog properties and variables.
.Parameter path
File path of json file.
.Parameter localVariables
Switch to determine whether we need to validate that variables with the name of the variableName exists or not in current session.
.Example
$ssisJson = Import-Json -path "C:\Users\SQLTraining\Documents\iscPublish.json"
#>
    param
    (
        [Parameter(Position = 0, mandatory = $true)]
        [String] $path,
        [Parameter(Position = 1, mandatory = $false)]
        [Switch] $localVariables
    )
    try {
        $json = Get-Content -Raw -Path $path -Encoding UTF8 | ConvertFrom-Json
        $jsonTested = Test-Json -jsonToTest $json
        if (!$localVariables)
        {
            Test-VariablesForPublishProfile -jsonPsCustomObject $jsonTested
        }
        return $jsonTested
    }
    catch {
        throw $_.Exception
    }
}
