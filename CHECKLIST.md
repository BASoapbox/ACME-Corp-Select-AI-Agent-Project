# Prerequisites Checklist

Everything you need in place **before** running the SQL scripts. Most failures in
this stack are provisioning problems wearing a misleading error message, so it is
worth walking this list rather than discovering them one `ORA-` at a time.

Work top to bottom. Each section ends with a way to prove it worked.

---

## 1. Local software

| | Needed | Notes |
|---|---|---|
| ☐ | **SQL client** | SQLcl, or SQL Developer Web (Database Actions) in the OCI console |
| ☐ | **OCI CLI** | Only for Object Storage upload and Vault. Console works too |

**SQLcl without a separate install:** the Oracle SQL Developer extension for VS Code
bundles SQLcl *and* its own JDK. You do not need a system Java, and you do not need
SQL Developer desktop (which the extension supersedes).

```
~/.vscode/extensions/oracle.sql-developer-<version>/dbtools/sqlcl/bin/sql
```

If you install SQLcl standalone instead, it needs **JDK 11+** on `PATH` — on macOS,
`/usr/bin/java` is a stub that is not a runtime.

**Prove it:** `sql -V` prints a release number.

---

## 2. Database

| | Needed |
|---|---|
| ☐ | Autonomous Database (ADW or ATP), **AVAILABLE** — not stopped |
| ☐ | `ADMIN` password, or another account with DBA privileges |
| ☐ | Wallet downloaded, **or** use Database Actions in the console (no wallet needed) |

**Prove it:** connect as ADMIN and run `SELECT * FROM v$version;`

---

## 3. Schema

| | Needed |
|---|---|
| ☐ | `ACME_CORP` schema **created** |
| ☐ | Its password recorded somewhere you can retrieve it |

> **The schema is not created by the grants script.** It must exist before you run
> the admin setup, which enables Resource Principal *for* `ACME_CORP` and grants
> *to* `ACME_CORP` — every statement assumes the user is already there.

The password is needed again later: the Python (OML4Py) custom tool authenticates
with it to refresh its OML token. If you plan to use that tool, store the password
in an OCI Vault secret now rather than rediscovering the need later.

**Prove it:**
```sql
SELECT username, account_status FROM dba_users WHERE username = 'ACME_CORP';
```

---

## 4. Grants — run as ADMIN

| | Needed | Why |
|---|---|---|
| ☐ | `EXECUTE` on `DBMS_CLOUD` | Object Storage, HTTP requests |
| ☐ | `EXECUTE` on `DBMS_CLOUD_AI` | Profiles, vector indexes |
| ☐ | `EXECUTE` on `DBMS_CLOUD_AI_AGENT` | Agents, tasks, teams, tools |
| ☐ | `EXECUTE` on `DBMS_CLOUD_ADMIN` | Resource Principal |
| ☐ | Resource Principal enabled | Credential-free calls to OCI |
| ☐ | `PYQADMIN` + `OML_DEVELOPER` roles | Only for the Python/EPE tool |
| ☐ | EPE network ACL | Only for the Python/EPE tool |

> **Direct grants only.** NL2SQL silently ignores privileges received through a
> role. `SELECT ANY TABLE` does **not** satisfy it — every source table needs an
> explicit `GRANT SELECT ON <table> TO <user>`. This one costs people days.

> The EPE network ACL is **not** `DBMS_NETWORK_ACL_ADMIN`. Embedded Python
> Execution uses a separate PYQSYS-managed ACL, and changes to the standard
> network ACL have no effect on it.

**Prove it:** connect as `ACME_CORP` and check
`USER_TAB_PRIVS_RECD` for the packages, `USER_ROLE_PRIVS` for the roles, and
`OCI$RESOURCE_PRINCIPAL` with `owner = 'ADMIN'` (it is owned by ADMIN, not by you).

---

## 5. OCI — IAM policies

> **Being a tenancy administrator does not cover this.** There are *two* principals
> here, and admin rights only help with one of them.
>
> | Principal | What it does | Covered by your admin role? |
> |---|---|---|
> | **You** — a human user | Creates the database, bucket, vault, schema | ✅ Yes |
> | **The database** — its Resource Principal | Calls Generative AI, reads the RAG documents | ❌ **No** |
>
> The database authenticates as itself, not as you. Without a policy naming that
> principal, every GenAI call and every vector-index build fails — no matter who
> you are. This is the single most common reason a correctly-written script fails
> on a fresh tenancy.

### Required — Select AI Agent

| | Needed |
|---|---|
| ☐ | Policy: database may call Generative AI |
| ☐ | Policy: database may read the RAG bucket |
| ☐ | Generative AI **available in your region** |
| ☐ | Your chat and embedding models exist **in that region** |

```
allow any-user to manage generative-ai-family in compartment <db-compartment>
  where request.principal.type = 'autonomousdatabase'

allow any-user to read object-family in compartment <bucket-compartment>
  where request.principal.type = 'autonomousdatabase'
```

`request.principal.type = 'autonomousdatabase'` scopes these to databases rather
than to people, so no dynamic group is required. Use a dynamic group instead if
you need to narrow it to one specific database.

**Creating it from the CLI.** A policy can only grant access to its own
compartment and that compartment's descendants — so if your database and bucket
live in sibling compartments, create the policy in their **shared parent**:

```bash
# find the parent compartment
oci iam compartment list --compartment-id-in-subtree true --all \
  --query 'data[].{name:name,id:id,parent:"compartment-id"}' --output table

# statements — a JSON array, one string per statement
cat > statements.json <<'JSON'
[
  "allow any-user to manage generative-ai-family in compartment <db-compartment> where request.principal.type = 'autonomousdatabase'",
  "allow any-user to read object-family in compartment <bucket-compartment> where request.principal.type = 'autonomousdatabase'"
]
JSON

oci iam policy create \
  --compartment-id <parent-compartment-ocid> \
  --name "pol-selectai-resource-principal" \
  --description "Allows Autonomous Database Resource Principals to call OCI Generative AI and read the RAG bucket." \
  --statements file://statements.json \
  --wait-for-state ACTIVE

# verify
oci iam policy list -c <parent-compartment-ocid> --all \
  --query 'data[].{name:name,state:"lifecycle-state"}' --output table
```

Inside the policy, child compartments are named **relative to the policy's own
compartment** — `in compartment cmp-x-db`, not the full path.

> IAM changes are eventually consistent. Allow a minute or so before assuming a
> new policy has not taken effect.

> **Watch the compartments.** These two statements often name *different*
> compartments — databases and buckets are frequently separated. A single
> compartment in both lines is a common and confusing failure. Put the policy in
> a shared parent compartment if you want one policy to cover both.

> `read object-family` is enough for RAG. `manage` is broader than the database
> needs.

### Only if you also use OCI GenAI Agent service

Not needed for Select AI Agent, which runs entirely in the database:

```
allow any-user to manage genai-agent-family in compartment <cmp> where request.principal.type = 'autonomousdatabase'
allow any-user to manage object-family      in compartment <cmp> where request.principal.type = 'genaiagent'
```

### Region

> **Check twice.** Generative AI is not available in every region, and model
> availability differs between the regions where it is. `meta.llama-3.3-70b-instruct`
> exists in some regions and not others. The region appears in the profile
> attributes, the Object Storage URL, and the OML endpoint — `SA_ENV.sql` derives
> the last two from the first so they cannot drift apart.

> `oci_compartment_id` defaults to the database's own compartment. If your GenAI
> resources live in a **different** compartment, set it explicitly or the SQL tool
> fails at execution time with `ORA-20052`.

**Prove it:** list the models your database can actually reach —

```bash
oci generative-ai model-collection list-models -c <compartment-ocid> \
  --query 'data.items[?"lifecycle-state"==`ACTIVE`]."display-name"'
```

If your configured `chat_model` is not in that list, nothing downstream will work.

---

## 6. Object Storage — only if using RAG

| | Needed |
|---|---|
| ☐ | Bucket created |
| ☐ | Knowledge base documents uploaded |
| ☐ | Object Storage namespace noted |
| ☐ | `rag_bucket` / `rag_prefix` set in `SA_ENV.sql` |

This repo ships seven sample documents in `rag-kb/`. To create a bucket and
upload them:

```bash
# namespace
oci os ns get --query data --raw-output

# bucket (skip if it already exists)
oci os bucket create -c <compartment-ocid> --name <bucket>

# upload
oci os object bulk-upload -bn <bucket> --src-dir ./rag-kb \
  --object-prefix acme-rag-kb/ --content-type application/pdf --overwrite

# verify
oci os object list -bn <bucket> --prefix acme-rag-kb/ \
  --query 'data[].{name:name,size:size}' --output table
```

Then set `rag_bucket` and `rag_prefix` in `SA_ENV.sql`; the full URL is derived:

```
https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<prefix>/
```

Supported: `.pdf .docx .pptx .xlsx .txt .html .md .xml .json`

> The bucket does **not** need to be public. The database reads it as its own
> Resource Principal — which is exactly what the `read object-family` policy in
> section 5 authorises.

> Documents must contain **extractable text**. A PDF that is a scanned image or a
> pure diagram contributes nothing to the vector index, and you get silence from a
> document you can plainly see in the bucket.

**Prove it:** after building the index, `SELECT COUNT(*)` on the vector store
returns more chunks than you have documents.

---

## 7. Values to collect

Have these to hand before you start — the scripts need them and hunting mid-run is
how you end up with a half-built stack.

| Value | Where it comes from | Yours |
|---|---|---|
| Compartment OCID | Console → Identity → Compartments | |
| Region | Console, e.g. `us-ashburn-1` | |
| Schema name | You choose (`ACME_CORP`) | |
| Schema password | You choose | *(vault it)* |
| Chat model | GenAI models in your region | |
| Embedding model | GenAI models in your region | |
| Object Storage namespace | Console → Tenancy details | |
| Bucket name / prefix | You choose | |
| OML endpoint URL | Console → ADB → Database Actions → OML RESTful Services | |

---

## 8. Run order

1. Create the schema — **as ADMIN**
2. Grants, Resource Principal, EPE ACL — **as ADMIN**
3. Tables and data — **as the schema owner**
4. Profiles, tools, agent, task, team — **as the schema owner**
5. Test

Each step verifies before the next one builds on it. Resist doing them at once —
the agent stack is opaque enough that when something breaks you very much want to
already know which layers are solid.

---

## When something fails

Work bottom-up. Each layer's errors impersonate a different layer's problems.

1. **Is the object valid?** `USER_ERRORS` — a PL/SQL object with a compile error is
   still *created*, just `INVALID`, and many drivers report that as success.
2. **Does it work standalone?** `SELECT your_function(...) FROM dual` — bypasses the
   agent entirely.
3. **What did the agent actually do?** `USER_AI_AGENT_TOOL_HISTORY` logs every tool
   invocation with inputs and output.

An invalid function surfaces at the agent layer as "procedure not found", which
reads like a missing grant. It is not.
