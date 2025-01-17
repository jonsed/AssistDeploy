Function Publish-SsisVariables {
    <#
.Synopsis
Publish and associate variables in publish json file to corresponding environment and project.
.Description
For each environment variable in json file, function checks if variable already exists.
If it does not exist then it creates it.
If it does exist then it checks if any of hte following have altered:
        value
        dataType
        Sensitivity
        description
If any of these have changed it alters those values only.
If both data type and value have changed, then current var is dropped and re-created, as blocking changes. 
Functionality to create/alter are in separate functions:
    new-ssisvariable
    set-environmentvariableproperty
    set-environmentvariableprotection
    set-environmentvariablevalue
.Parameter jsonPsCustomObject
Tested json object loaded from Import-Json
.Parameter sqlConnection
The SQL Connection to SSISDB
.Parameter ssisFolderName
Optional parameter. We may wish to override the value of what is in the json file.
.Parameter ssisEnvironmentName
Optional parameter. We may wish to override the value of what is in the json file.
.Parameter ssisProjectName
Optional parameter. We may wish to override the value of what is in the json file.
.Parameter LocalVariables
Optional parameter. If used then values stored in json file are used. If not used then PowerShell variables need to exist either 
as full PS variables (e.g. $Foo) or Environment variables (e.g. $Env:Foo) that have the same name as variables in json file.
.Parameter WhatIf
Optional parameter. If used then no changes are made on server.
.Parameter variableType
Variables can be either full Powershell variables (e.g. $Foo) or Environment variables (e.g. $Env:Foo).
.Example
Publish-SsisVariables -ssisPublishFilePath $thisSsisPublishFilePath -sqlConnection $ssisdb -localVariables
Non-mandatory params here can be used to overwrite the values stored in the publish json file passed in
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, mandatory = $true)]
        [PSCustomObject] $jsonPsCustomObject,
        [Parameter(Position = 1, mandatory = $true)]
        [System.Data.SqlClient.SqlConnection] $sqlConnection,
        [Parameter(Position = 2, mandatory = $false)]
        [String] $ssisFolderName,
        [Parameter(Position = 3, mandatory = $false)]
        [String] $ssisEnvironmentName,
        [Parameter(Position = 4, mandatory = $false)]
        [String] $ssisProjectName,
        [Parameter(Position = 5, mandatory = $false)]
        [Switch] $localVariables,
        [Parameter(Position = 6, mandatory = $false)]
        [Switch] $whatIf,
        [Parameter(Position = 7, mandatory = $false)]
        [ValidateSet('Env', 'PS')]
        [string] $variableType = 'PS'
    )
    $ssisJson = $jsonPsCustomObject
    $ssisProperties = New-IscProperties -jsonObject $ssisJson
    if ($ssisFolderName) {
        $ssisProperties = Set-IscProperty -iscProperties $ssisProperties -newSsisFolderName $ssisFolderName
    }
    if ($ssisEnvironmentName) {
        $ssisProperties = Set-IscProperty -iscProperties $ssisProperties -newSsisEnvironmentName $ssisEnvironmentName
    }
    if ($ssisProjectName) {
        $ssisProperties = Set-IscProperty -iscProperties $ssisProperties -newSsisProjectName $ssisProjectName
    }
    if (!$localVariables) {
        $keys = @()
        $keys += $ssisJson.ssisEnvironmentVariable
        foreach ($var in $keys) {
            $varName = $var.VariableName
            if (Test-Variable -variableName $varName -variableType $variableType) {
                $value = Get-VariableByType -variableName $varName -variableType $variableType
                Write-Verbose ('Setting ssisEnvironmentVariable variable: {0} = {1}' -f $varName, $value) -Verbose
                $ssisJson.ssisEnvironmentVariable[$keys.IndexOf($var)].value = $value
            }
            else {
                [string]$missingVariables += $var.VariableName
            }
        }
        if ($missingVariables.Count -gt 0) {
            throw ('The following ssisEnvironmentVariable variables are not defined in the session as {0} (but are defined in the json file): {1}' -f $variableType, ($missingVariables -join " `n"))

        }
    }
    $sqlDropVars = "
                SELECT referenced_variable_name = c.name
                ,sensitive = CASE c.sensitive
                    WHEN 0
                        THEN 'False'
                    ELSE 'True'
                    END
                ,c.description
                ,data_type = c.type
                ,c.value
            FROM SSISDB.CATALOG.folders a
            INNER JOIN SSISDB.CATALOG.environments b ON a.folder_id = b.folder_id
            INNER JOIN SSISDB.CATALOG.environment_variables c ON b.environment_id = c.environment_id
            INNER JOIN internal.projects p ON a.folder_id = p.folder_id
            LEFT JOIN CATALOG.environment_references er ON er.environment_name = b.name
                AND er.environment_folder_name = a.name
            WHERE p.name = @1
                AND a.name = @2
                AND (
                    b.name = @0
                    OR b.name IS NULL
                    )
            "
    $sqlCmdDropVars = New-Object System.Data.SqlClient.SqlCommand($sqlDropVars, $sqlConnection)
    $sqlCmdDropVars.Parameters.AddWithValue("@0", $ssisProperties.ssisEnvironmentName) | Out-Null
    $sqlCmdDropVars.Parameters.AddWithValue("@1", $ssisProperties.ssisProjectName) | Out-Null
    $sqlCmdDropVars.Parameters.AddWithValue("@2", $ssisProperties.ssisFolderName) | Out-Null
    $sqlDropVarAdapter = New-Object System.Data.SqlClient.SqlDataAdapter $sqlCmdDropVars
    $sqlDropVarDataset = New-Object System.Data.DataSet
    $sqlDropVarAdapter.Fill($sqlDropVarDataset) | Out-Null
    $sqlDropVarDataTable = $sqlDropVarDataSet.Tables[0]
    Write-Verbose "$($sqlDropVarDataTable.Rows.Count) variables found." -Verbose
    for ($i = 0; $i -lt $sqlDropVarDataTable.Rows.Count; $i++) {
        $sqlVarToDrop = $sqlDropVarDataTable.Rows[$i][0]
        if (($ssisJson.ssisEnvironmentVariable.VariableName -contains $sqlVarToDrop) -eq $false) {
            $sqlDropVar = "
            EXEC CATALOG.delete_environment_variable @folder_name = @2
            ,@environment_name = @0
            ,@variable_name = @1"
            $sqlCmdDropVar = New-Object System.Data.SqlClient.SqlCommand($sqlDropVar, $sqlConnection)
            $sqlCmdDropVar.Parameters.AddWithValue("@0", $ssisProperties.ssisEnvironmentName) | Out-Null
            $sqlCmdDropVar.Parameters.AddWithValue("@1", $sqlVarToDrop) | Out-Null
            $sqlCmdDropVar.Parameters.AddWithValue("@2", $ssisProperties.ssisFolderName) | Out-Null
            try {
                Write-Verbose "Dropping $sqlVarToDrop" -Verbose
                if (!$whatIf) {
                    $sqlCmdDropVar.ExecuteNonQuery() | Out-Null
                }
            }
            catch {
                throw $_.Exception
            }
        }
    }
    foreach ($ssisVariable in $ssisJson.ssisEnvironmentVariable) {
        $whatIs = $sqlDropVarDataTable.Select("referenced_variable_name = '$($ssisVariable.variableName)'")
        if ($null -eq $whatIs.ItemArray) {
            if (!$whatIf) {
                New-SsisVariable -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties
            }
        }
        else {
            Write-Verbose "Variable $($ssisVariable.Variablename) already exists. Checking for inconsistencies with server version. If any are found then variable will be altered." -Verbose
            [bool]$altered = $false
            if ($whatIs.value -ne $ssisVariable.value) {
                $altered = $true
                if ($whatIs.data_type -ne $ssisVariable.dataType) {
                    Write-Verbose "As both data type and value of $($ssisVariable.variablename) have altered, we will need to drop and re-create." -Verbose
                    if (!$whatIf) {
                        New-SsisVariable -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties            
                    }
                }
                else {
                    Write-Verbose "Value of $($ssisVariable.Variablename) needs to be updated." -Verbose
                    if (!$whatIf) {
                        Set-EnvironmentVariableValue -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties       
                    } 
                }
            }
            if ($whatIs.Sensitive -ne $ssisVariable.isSensitive) {
                $altered = $true
                Write-Verbose "Protection level of $($ssisVariable.Variablename) needs to be updated." -Verbose
                if (!$whatIf) {
                    Set-EnvironmentVariableProtection -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties
                }
                Write-Verbose "As protection level has altered, value of $($ssisVariable.Variablename) needs to be updated." -Verbose
                if (!$whatIf) {
                    Set-EnvironmentVariableValue -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties 
                }
            }
            if ($whatIs.Description -ne $ssisVariable.Description) {
                $altered = $true
                Write-Verbose "Description of $($ssisVariable.Variablename) needs to be updated." -Verbose
                if (!$whatIf) {
                    Set-EnvironmentVariableProperty -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties -PropertyName "Description" -PropertyValue $ssisVariable.Description
                }
            }
            if ($whatIs.data_type -ne $ssisVariable.dataType) {
                $altered = $true
                Write-Verbose "Data Type of $($ssisVariable.Variablename) needs to be updated." -Verbose
                if (!$whatIf) {
                    Set-EnvironmentVariableProperty -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties -PropertyName "Type" -PropertyValue $ssisVariable.dataType
                }
            }
            if ($altered -eq $false) {
                Write-Verbose "Variable $($ssisVariable.Variablename) not altered." -Verbose
            }
        }
        if (!$whatIf) {
            Set-ObjectParameterValue -sqlConn $sqlConnection -ssisVar $ssisVariable -ssisProp $ssisProperties
        }
    }
}