# QA: Checkpoint D (Tasks 12–14 host checks)

A step-by-step script for the open Phase 4 checks in [todo.md](./todo.md). Tick each box as you
go, and note anything unexpected under it. Each check is tagged with the task-list item it closes,
for example **[T12-a]**, so the results can be copied back.

Run everything from `ed-fi-api-v8/`. The kit must be on the current `dms-compose` branch.

> **Secrets:** `new-credential` prints a key and secret, and `smoke-test --debug` prints more.
> Don't paste that output into tickets, chats, or AI tools. Blank out the secrets first.

## Item key

| Tag | Task-list item |
| --- | --- |
| T12-a | Same flags and same output on bash and pwsh |
| T12-b | `start` against a running stack exits 0, with no changes |
| T12-c | `reset` without confirmation does nothing |
| T12-v | Manual runs of each command, in both shells |
| T13-a | Each shape yields a credential whose first authorized request succeeds with no extra configuration |
| T13-b | Reusing an existing `--name` fails without modifying the existing registration |
| T13-c | CMS down → exit non-zero with "run start first" |
| T13-v | Token plus a GET for each shape; POST a school with a SIS credential → 403 |
| T14-a | `smoke-test` exits 0 on a fresh minimal and a fresh populated start; non-zero when DMS is stopped |
| T14-b | `edorgs.http` re-run against a bootstrapped environment → no errors, no duplicates |
| T14-c | Populated-only requests fail with a recognizable message on minimal |
| T14-v | Smoke test in both shells; both `.http` files in VS Code REST Client |
| CP-D | Walk through start → credential → smoke → first request, for each shape, on a clean volume |

## Helpers: get a token and make a request with a credential file

Use these whenever a step says "first request". They read the key and secret from the file
`new-credential` saved, so nothing has to be copied by hand. `-k` / `-SkipCertificateCheck` is
fine here: the certificate is the kit's own self-signed one.

Bash (needs `jq`; in Git Bash without `jq`, use the PowerShell version):

```bash
# usage: req <credential-name> <METHOD> <path> [json-body]   e.g.  req qa-sis GET /data/ed-fi/schools?limit=1
req() {
    local cred=".runtime/credentials/$1.json" token
    token=$(curl -sk -u "$(jq -r .key "$cred"):$(jq -r .secret "$cred")" \
        -d grant_type=client_credentials https://localhost/api/oauth/token | jq -r .access_token)
    curl -sk -o /dev/null -w "HTTP %{http_code}\n" -X "$2" "https://localhost/api$3" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" ${4:+-d "$4"}
}
```

PowerShell 7:

```powershell
# usage: req qa-sis GET '/data/ed-fi/schools?limit=1' [json-body]
function req($Name, $Method, $Path, $Body) {
    $c = Get-Content ".runtime/credentials/$Name.json" | ConvertFrom-Json
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($c.key):$($c.secret)"))
    $token = (Invoke-RestMethod -Method Post -Uri https://localhost/api/oauth/token -SkipCertificateCheck `
        -Headers @{ Authorization = "Basic $basic" } -Body @{ grant_type = 'client_credentials' }).access_token
    $r = Invoke-WebRequest -Method $Method -Uri "https://localhost/api$Path" -SkipCertificateCheck `
        -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $Body `
        -SkipHttpErrorCheck
    "HTTP $($r.StatusCode)"
}
```

If you changed `HTTPS_PORT` or `DMS_PATH_BASE` in `.env`, adjust `https://localhost/api` to match.

---

## Part 1: Minimal template, Bash

### 1.1 Clean start

```bash
./reset.sh --force
./start.sh --template minimal; echo "exit=$?"
```

- [x] `exit=0`, and the output lists the URLs, `Template in use: minimal`, the bootstrap credentials
      path, and a next step **[T12-v]**

### 1.2 `start` again on a running stack **[T12-b]**

```bash
docker compose ps --format '{{.Name}} {{.CreatedAt}}' > /tmp/before.txt
./start.sh; echo "exit=$?"
docker compose ps --format '{{.Name}} {{.CreatedAt}}' > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "no containers recreated"
```

- [x] `exit=0` and `no containers recreated`

### 1.3 Smoke test on a fresh minimal start **[T14-a] [T14-v]**

```bash
./smoke-test.sh; echo "exit=$?"
```

- [x] Every step PASS (assessment-write SKIP on minimal), `exit=0`

### 1.4 One credential per shape **[T13-a] [T13-v] [CP-D]**

```bash
./new-credential.sh --shape sis --name qa-sis; echo "exit=$?"
./new-credential.sh --shape assessment --name qa-assessment; echo "exit=$?"
./new-credential.sh --shape warehouse --name qa-warehouse; echo "exit=$?"
```

- [x] All three print a key, secret, token URL, and `Saved to: ...`, with `exit=0` and no
      "could not be verified" warning

First requests, with no other setup:

```bash
req qa-sis        GET /data/ed-fi/schools?limit=1     # expect HTTP 200
req qa-assessment GET /data/ed-fi/assessments?limit=1 # expect HTTP 200 (an empty list is fine)
req qa-warehouse  GET /data/ed-fi/schools?limit=1     # expect HTTP 200 (also Task 11: 200, not 500)
req qa-sis POST /data/ed-fi/schools '{"schoolId":990099,"nameOfInstitution":"QA","educationOrganizationCategories":[{"educationOrganizationCategoryDescriptor":"uri://ed-fi.org/EducationOrganizationCategoryDescriptor#School"}],"gradeLevels":[{"gradeLevelDescriptor":"uri://ed-fi.org/GradeLevelDescriptor#Kindergarten"}]}'
                                                      # expect HTTP 403 (SIS can't create schools)
```

- [x] sis GET 200
- [x] assessment GET 200
- [x] warehouse GET 200
- [x] sis POST school 403

### 1.5 Reusing a name **[T13-b]**

```bash
./new-credential.sh --shape sis --name qa-sis; echo "exit=$?"
req qa-sis GET /data/ed-fi/schools?limit=1
```

- [x] Non-zero exit with a message that the name is taken
- [x] `.runtime/credentials/qa-sis.json` is unchanged, and the original credential still returns
      HTTP 200

### 1.6 CMS down **[T13-c]**

```bash
docker compose stop config
./new-credential.sh --shape sis --name qa-cms-down; echo "exit=$?"
./start.sh
```

- [x] Non-zero exit with `CMS is not reachable: run ./start.sh (or start.ps1) first`
- [x] `./start.sh` brings `config` back (exit 0)

### 1.7 Smoke test with DMS stopped **[T14-a]**

```bash
docker compose stop dms
./smoke-test.sh; echo "exit=$?"
./start.sh
```

- [x] FAIL lines and a non-zero exit, not a hang
- [x] `./start.sh` brings `dms` back (exit 0)

### 1.8 `bootstrap` and `stop` **[T12-v]**

```bash
./bootstrap.sh; echo "exit=$?"          # on the running stack
./stop.sh; echo "exit=$?"
./bootstrap.sh; echo "exit=$?"          # on the stopped stack
./start.sh
req qa-sis GET /data/ed-fi/schools?limit=1
```

- [x] `bootstrap` on the running stack exits 0 and creates nothing new (no duplicate vendor,
      application, or education organizations)
- [x] `stop` exits 0
- [x] `bootstrap` on the stopped stack fails with a clear "start first" message
- [x] After `start`, the credential created before `stop` still returns HTTP 200 (data kept)

### 1.9 `reset` without confirmation **[T12-c]**

```bash
./reset.sh; echo "exit=$?"              # answer: no
./reset.sh < /dev/null; echo "exit=$?"  # no terminal to ask
docker compose ps
req qa-sis GET /data/ed-fi/schools?limit=1
```

- [x] Both exit non-zero and say nothing was changed
- [x] Containers still running, and the credential still returns HTTP 200

### 1.10 Request files in VS Code REST Client **[T14-b] [T14-c] [T14-v]**

Put the key and secret from `.runtime/bootstrap-credentials.json` into `@key` / `@secret` (or a
REST Client environment; see the comments at the top of `http/smoke.http`). Don't commit them.

- [x] `http/smoke.http`: requests 1–9 succeed with the expected status codes
- [x] `http/smoke.http` step 10 (populated only), run on minimal with the bootstrap credential, fails
      with a message that says why, not an empty success **[T14-c]**. Note the status and message
      of both requests. The `studentAssessments` request should name the unresolved reference. The
      `assessments` request may instead return 403, because the bootstrap vendor on minimal may not
      have the `uri://gbisd.edu` namespace. If so, say whether that message is clear enough.
- [x] `http/edorgs.http`: run every request, then run them all again. No errors either time, and
      `GET /data/ed-fi/schools?totalCount=true` shows the same `Total-Count` after both runs **[T14-b]**

---

## Part 2: Minimal template, PowerShell

Same flow in PowerShell 7 (`pwsh`), with different credential names. Note any difference in
wording or exit codes from Part 1 under **[T12-a]**.

```powershell
.\reset.ps1 -Force
.\start.ps1 -Template minimal; "exit=$LASTEXITCODE"
.\start.ps1; "exit=$LASTEXITCODE"
.\smoke-test.ps1; "exit=$LASTEXITCODE"
.\new-credential.ps1 -Shape sis -Name qa-sis-ps; "exit=$LASTEXITCODE"
.\new-credential.ps1 -Shape assessment -Name qa-assessment-ps; "exit=$LASTEXITCODE"
.\new-credential.ps1 -Shape warehouse -Name qa-warehouse-ps; "exit=$LASTEXITCODE"
req qa-sis-ps GET '/data/ed-fi/schools?limit=1'
req qa-assessment-ps GET '/data/ed-fi/assessments?limit=1'
req qa-warehouse-ps GET '/data/ed-fi/schools?limit=1'
.\new-credential.ps1 -Shape sis -Name qa-sis-ps; "exit=$LASTEXITCODE"   # name reuse
.\bootstrap.ps1; "exit=$LASTEXITCODE"
.\stop.ps1; "exit=$LASTEXITCODE"
.\start.ps1; "exit=$LASTEXITCODE"
.\reset.ps1; "exit=$LASTEXITCODE"                                      # answer: no
```

- [x] `start` exit 0; second `start` exit 0 with no changes **[T12-b]**
- [x] `smoke-test` exit 0 **[T14-v]**
- [x] Three credentials created; three first requests HTTP 200 **[T13-a]**
- [x] Name reuse fails and leaves the original working **[T13-b]**
- [x] `bootstrap`, `stop`, `start` behave as in Part 1 **[T12-v]**
- [x] `reset` answered "no" changes nothing **[T12-c]**

Same flags and output **[T12-a]**:

```powershell
foreach ($s in 'start','stop','reset','bootstrap','new-credential','smoke-test') {
    "=== $s"; & "./$s.ps1" -Help
}
```

```bash
for s in start stop reset bootstrap new-credential smoke-test; do echo "=== $s"; ./$s.sh --help; done
```

- [x] Each script has the same options in both shells (`--template` ↔ `-Template`, and so on;
      `smoke-test --debug` ↔ `-DebugCredentials` is the one intended difference)
- [x] Normal and error output reads the same in both shells, apart from path styles

Optional, if you have it: repeat `start`, `smoke-test`, and one `new-credential` in Windows
PowerShell 5.1 (`powershell.exe`). It's untested there.

---

## Part 3: Populated template

```bash
./reset.sh --force
./start.sh --template populated; echo "exit=$?"
./smoke-test.sh; echo "exit=$?"
./new-credential.sh --shape sis --name qa-sis-pop; echo "exit=$?"
./new-credential.sh --shape assessment --name qa-assessment-pop; echo "exit=$?"
./new-credential.sh --shape warehouse --name qa-warehouse-pop; echo "exit=$?"
req qa-sis-pop        GET /data/ed-fi/students?limit=1   # expect 200 (sample LEA 255901)
req qa-assessment-pop GET /data/ed-fi/students?limit=1   # expect 200
req qa-warehouse-pop  GET /data/ed-fi/students?limit=1   # expect 200
```

- [x] `start` exit 0 with `Template in use: populated` **[CP-D]**
- [x] `smoke-test` exit 0, with `assessment-write` PASS **[T14-a]**
- [x] Three credentials created; three first requests HTTP 200 **[T13-a] [CP-D]**
- [x] `.\smoke-test.ps1` also passes **[T14-v]**
- [x] REST Client: `http/smoke.http` step 10 with the `qa-assessment-pop` key and secret and a real
      `studentUniqueId` (see the step's comments): both POSTs return 200 or 201

---

## Results

When you're done, tell me which boxes are ticked and paste any failing output with the secrets
blanked out. I'll update [todo.md](./todo.md) and fix anything that failed.
