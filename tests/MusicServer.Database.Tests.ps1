$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Get-TestSqliteExecutable {
    if ($env:MUSICSERVER_SQLITE) {
        return $env:MUSICSERVER_SQLITE
    }
    return (Get-Command sqlite3.exe -ErrorAction Stop).Source
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
            { Invoke-MusicServerSqlNonQuery -Query 'INSERT INTO child(parent_id) VALUES (99);' } | Should Throw
        }
        [int](@(Invoke-MusicServerSqlJson -Query 'SELECT count(*) AS n FROM child;')[0].n) | Should Be 0
    }

    It 'commits valid transactions and rolls back a foreign-key failure before later statements' {
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(parent_id INTEGER REFERENCES parent(id));'
        Invoke-MusicServerSqlNonQuery -Query "BEGIN; INSERT INTO parent VALUES (1); INSERT INTO child VALUES (1); COMMIT;"
        foreach ($failure in @('INSERT INTO child VALUES (999)', 'INSERT INTO missing_table VALUES (999)')) {
            foreach ($separator in @(' ', "`n")) {
                $sql = @('BEGIN;', 'INSERT INTO parent VALUES (2);', ($failure + ';'), 'INSERT INTO parent VALUES (3);', 'COMMIT;') -join $separator
                { Invoke-MusicServerSqlNonQuery -Query $sql } | Should Throw
                $parents = @(Invoke-MusicServerSqlJson -Query 'SELECT id FROM parent ORDER BY id;')
                $parents.Count | Should Be 1
                [int]$parents[0].id | Should Be 1
            }
        }
        [int](@(Invoke-MusicServerSqlJson -Query 'SELECT count(*) AS n FROM child;')[0].n) | Should Be 1
    }

    It 'stops later autocommit statements after the first failure on the same line' {
        Invoke-MusicServerSqlNonQuery -Query 'CREATE TABLE bail_test(id INTEGER PRIMARY KEY);'
        { Invoke-MusicServerSqlNonQuery -Query 'INSERT INTO bail_test VALUES (1); INSERT INTO bail_test VALUES (1); INSERT INTO bail_test VALUES (2);' } | Should Throw
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
}
