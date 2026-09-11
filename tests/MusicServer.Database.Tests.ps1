$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Get-TestSqliteExecutable {
    if ($env:MUSICSERVER_SQLITE) {
        return $env:MUSICSERVER_SQLITE
    }
    return (Get-Command sqlite3.exe -ErrorAction Stop).Source
}

function Assert-TestThrows {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    $threw | Should Be $true
}

Describe 'MusicServer SQLite CLI database wrapper' {
    BeforeEach {
        $TestRoot = Join-Path ([IO.Path]::GetTempPath()) "musicserver_db_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
        Import-Module (Join-Path $ProjectRoot 'MusicServer.Database.psm1') -Force
        $DbPath = Join-Path $TestRoot 'wrapper.db'
        Initialize-MusicServerDatabase -DbPath $DbPath -SqliteExe (Get-TestSqliteExecutable) | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'keeps NULL integer boolean and text parameter types distinct' {
        $rows = @(Invoke-MusicServerParamSql -Template @"
SELECT
    @null_value AS null_value,
    typeof(@null_value) AS null_type,
    @integer_value AS integer_value,
    typeof(@integer_value) AS integer_type,
    @true_value AS true_value,
    typeof(@true_value) AS true_type,
    @false_value AS false_value,
    typeof(@false_value) AS false_type,
    @text_value AS text_value,
    typeof(@text_value) AS text_type;
"@ -Params @{
            null_value = $null
            integer_value = [long]42
            true_value = $true
            false_value = $false
            text_value = '42'
        })

        $rows.Count | Should Be 1
        $rows[0].null_value | Should Be $null
        $rows[0].null_type | Should Be 'null'
        [long]$rows[0].integer_value | Should Be 42
        $rows[0].integer_type | Should Be 'integer'
        [int]$rows[0].true_value | Should Be 1
        $rows[0].true_type | Should Be 'integer'
        [int]$rows[0].false_value | Should Be 0
        $rows[0].false_type | Should Be 'integer'
        $rows[0].text_value | Should Be '42'
        $rows[0].text_type | Should Be 'text'
    }

    It 'expands only exact parameter tokens from the original SQL template once' {
        $rows = @(Invoke-MusicServerParamSql -Template @"
SELECT
    @z_value AS value,
    @a_token AS token,
    @id AS id,
    @id2 AS id2,
    'literal @id text' AS literal_text,
    '-- @id is not a parameter here' AS comment_like_text;
"@ -Params @{
            z_value = 'keep @a_token unchanged'
            a_token = 'replacement'
            id = 7
            id2 = 72
        })

        $rows.Count | Should Be 1
        $rows[0].value | Should Be 'keep @a_token unchanged'
        $rows[0].token | Should Be 'replacement'
        [int]$rows[0].id | Should Be 7
        [int]$rows[0].id2 | Should Be 72
        $rows[0].literal_text | Should Be 'literal @id text'
        $rows[0].comment_like_text | Should Be '-- @id is not a parameter here'
    }

    It 'round-trips apostrophes newlines token-like text semicolons and Unicode' {
        # Build non-ASCII input from code points so Windows PowerShell 5.1 does
        # not depend on whether this UTF-8 test file has a BOM.
        $snow = [char]0x96EA
        $value = "'`n''`n@title`n@title2`n;`nUnicode $snow`r`nend"
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT @value AS value;' -Params @{ value = $value })

        $rows.Count | Should Be 1
        $rows[0].value | Should Be $value
    }

    It 'returns exact affected rows only when explicitly requested' {
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE changes_test (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL);'
        $inserted = Invoke-MusicServerParamNonQuery -Template 'INSERT INTO changes_test (id, revision) VALUES (@id, @revision);' -Params @{ id = 1; revision = 10 } -ReturnChanges
        $updated = Invoke-MusicServerParamNonQuery -Template 'UPDATE changes_test SET revision = revision + 1 WHERE id = @id AND revision = @revision;' -Params @{ id = 1; revision = 10 } -ReturnChanges
        $stale = Invoke-MusicServerParamNonQuery -Template 'UPDATE changes_test SET revision = revision + 1 WHERE id = @id AND revision = @revision;' -Params @{ id = 1; revision = 10 } -ReturnChanges

        $inserted | Should Be 1
        $updated | Should Be 1
        $stale | Should Be 0
    }

    It 'keeps sortable UTC timestamps as TEXT on every PowerShell edition' {
        $timestamp = '2026-08-28T03:25:17.123Z'
        $rows = @(Invoke-MusicServerParamSql -Template 'SELECT @timestamp AS timestamp;' -Params @{ timestamp = $timestamp })

        $rows.Count | Should Be 1
        $rows[0].timestamp.GetType().FullName | Should Be 'System.String'
        $rows[0].timestamp | Should Be $timestamp
    }

    It 'enforces foreign keys on every fresh SQLite process including reconnected databases' {
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(parent_id INTEGER REFERENCES parent(id));'
        foreach ($reconnect in @($false, $true)) {
            if ($reconnect) { Connect-MusicServerDatabase -DbPath $DbPath -SqliteExe (Get-TestSqliteExecutable) }
            $settings = @(Invoke-MusicServerSqlJson -Query 'PRAGMA foreign_keys;')
            [int]$settings[0].foreign_keys | Should Be 1
            Assert-TestThrows { Invoke-MusicServerSqlNonQuery -Query 'INSERT INTO child(parent_id) VALUES (99);' }
        }
        [int](@(Invoke-MusicServerSqlJson -Query 'SELECT count(*) AS n FROM child;')[0].n) | Should Be 0
    }

    It 'commits valid transactions and rolls back a foreign-key failure before later statements' {
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(parent_id INTEGER REFERENCES parent(id));'
        Invoke-MusicServerSqlNonQuery -Query "BEGIN; INSERT INTO parent VALUES (1); INSERT INTO child VALUES (1); COMMIT;"
        foreach ($failure in @('INSERT INTO child VALUES (999)', 'INSERT INTO missing_table VALUES (999)')) {
            foreach ($separator in @(' ', "`n")) {
                $sql = @('BEGIN;', 'INSERT INTO parent VALUES (2);', ($failure + ';'), 'INSERT INTO parent VALUES (3);', 'COMMIT;') -join $separator
                Assert-TestThrows { Invoke-MusicServerSqlNonQuery -Query $sql }
                $parents = @(Invoke-MusicServerSqlJson -Query 'SELECT id FROM parent ORDER BY id;')
                $parents.Count | Should Be 1
                [int]$parents[0].id | Should Be 1
            }
        }
        [int](@(Invoke-MusicServerSqlJson -Query 'SELECT count(*) AS n FROM child;')[0].n) | Should Be 1
    }

    It 'stops later autocommit statements after the first failure on the same line' {
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE bail_test(id INTEGER PRIMARY KEY);'
        Assert-TestThrows { Invoke-MusicServerSqlNonQuery -Query 'INSERT INTO bail_test VALUES (1); INSERT INTO bail_test VALUES (1); INSERT INTO bail_test VALUES (2);' }
        $rows = @(Invoke-MusicServerSqlJson -Query 'SELECT id FROM bail_test;')
        $rows.Count | Should Be 1
        [int]$rows[0].id | Should Be 1
    }

    It 'preserves quoted semicolons comments and complete trigger bodies when separating statements' {
        Invoke-MusicServerSqlNonQuery -Query @'
CREATE TABLE [source;table](id INTEGER PRIMARY KEY, "text;column" TEXT); CREATE TABLE `audit;table`(value TEXT);
CREATE TRIGGER audit_insert AFTER INSERT ON [source;table] BEGIN INSERT INTO `audit;table` VALUES (NEW."text;column"); INSERT INTO `audit;table` VALUES ('trigger;second'); END; INSERT INTO [source;table] VALUES (1, 'quote'';@token
next;line'); -- comment; INSERT INTO missing_table VALUES (1);
/* comment; ' " ` [ */ INSERT INTO [source;table] VALUES (2, 'last;value');
'@
        $rows = @(Invoke-MusicServerSqlJson -Query 'SELECT value FROM `audit;table` ORDER BY rowid;')
        $rows.Count | Should Be 4
        $rows[0].value | Should Be "quote';@token`nnext;line"
        $rows[1].value | Should Be 'trigger;second'
        $rows[2].value | Should Be 'last;value'
        $rows[3].value | Should Be 'trigger;second'
    }

    It 'reconnects without modifying the existing journal mode or schema' {
        Invoke-MusicServerSqlNonQuery -Query 'PRAGMA journal_mode=DELETE; PRAGMA user_version=17;'
        Connect-MusicServerDatabase -DbPath $DbPath -SqliteExe (Get-TestSqliteExecutable)
        [string](@(Invoke-MusicServerSqlJson -Query 'PRAGMA journal_mode;')[0].journal_mode) | Should Be 'delete'
        (Get-SchemaVersion) | Should Be 17
        [int](@(Invoke-MusicServerSqlJson -Query 'PRAGMA busy_timeout;')[0].timeout) | Should Be 5000
    }

    It 'returns one row as a flat row, never a wrapper array wrapping that row' {
        # PS 5.1's ConvertFrom-Json returned a one-item JSON array nested inside
        # another array. Scalar member access hid it, but property lookups did not:
        # @(rows)[0].title answered correctly while @(rows)[0] was really the list.
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE probe (title TEXT NOT NULL); INSERT INTO probe (title) VALUES (''only row'');'
        $rows = @(Invoke-MusicServerSqlJson -Query 'SELECT title FROM probe;')
        $rows.Count | Should Be 1
        $rows[0].GetType().Name | Should Be 'PSCustomObject'
        [string]$rows[0].title | Should Be 'only row'
    }
}

Describe 'MusicServer JSON array parsing' {
    It 'flattens a JSON array at every length' {
        @(ConvertFrom-MusicServerJsonArray -Json '[]').Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json '[{"a":1}]').Count | Should Be 1
        @(ConvertFrom-MusicServerJsonArray -Json '[{"a":1},{"a":2}]').Count | Should Be 2
        @(ConvertFrom-MusicServerJsonArray -Json '[{"a":1},{"a":2},{"a":3}]').Count | Should Be 3
    }

    It 'exposes the items themselves rather than a nested list' {
        # The regression that mattered: every reader of identifiers_json saw a
        # wrapper, so Get-NeteaseIdFromTrack returned '' for every stored track.
        $items = @(ConvertFrom-MusicServerJsonArray -Json '[{"type":"netease","value":"4242"}]')
        $items[0].GetType().Name | Should Be 'PSCustomObject'
        [string]$items[0].type | Should Be 'netease'
        [string]$items[0].value | Should Be '4242'
    }

    It 'returns nothing for absent, empty, malformed or non-array input' {
        @(ConvertFrom-MusicServerJsonArray -Json $null).Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json '').Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json '   ').Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json '[]').Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json 'not json at all').Count | Should Be 0
        # A bare object is not a list of items and must not become a one-item list.
        @(ConvertFrom-MusicServerJsonArray -Json '{}').Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json '{"a":1}').Count | Should Be 0
    }

    It 'drops JSON null holes rather than reporting them as items' {
        # New-CanonicalTrack once turned a missing -Identifiers into @($null), which
        # reached disk as [null]. A null is not an item.
        @(ConvertFrom-MusicServerJsonArray -Json '[null]').Count | Should Be 0
        @(ConvertFrom-MusicServerJsonArray -Json '[null,null]').Count | Should Be 0
        $mixed = @(ConvertFrom-MusicServerJsonArray -Json '[null,{"type":"netease","value":"7"}]')
        $mixed.Count | Should Be 1
        [string]$mixed[0].value | Should Be '7'
    }

    It 'unwraps the legacy ConvertTo-Json collection wrapper shape' {
        # ConvertTo-Json renders an ArrayList as {value:[...],Count:n} rather than an
        # array, so rows written that way must still yield their real items.
        $items = @(ConvertFrom-MusicServerJsonArray -Json '[{"value":[{"type":"netease","value":"777"}],"Count":1}]')
        $items.Count | Should Be 1
        [string]$items[0].type | Should Be 'netease'
        [string]$items[0].value | Should Be '777'
    }

    It 'writes an array that its own reader round-trips, with no null holes' {
        (ConvertTo-MusicServerJsonArrayText -Items @()) | Should Be '[]'
        (ConvertTo-MusicServerJsonArrayText -Items $null) | Should Be '[]'
        (ConvertTo-MusicServerJsonArrayText -Items @($null)) | Should Be '[]'
        foreach ($case in @(
            , @([pscustomobject]@{ type = 'netease'; value = '1' })
            , @([pscustomobject]@{ type = 'netease'; value = '1' }, [pscustomobject]@{ type = 'netease'; value = '2' })
            , @([pscustomobject]@{ type = 'netease'; value = '1' }, [pscustomobject]@{ type = 'netease'; value = '2' }, [pscustomobject]@{ type = 'netease'; value = '3' })
        )) {
            $text = ConvertTo-MusicServerJsonArrayText -Items $case
            $text.StartsWith('[') | Should Be $true
            @(ConvertFrom-MusicServerJsonArray -Json $text).Count | Should Be $case.Count
        }
    }
}
