# ExMCP 1.6 maintenance release

This release retains `{:ex_mcp, "~> 1.0"}`, the `:ex_mcp` application and
`ExMCP.*` namespaces, including the built-in `ExMCP.ACP.*` adapters. It does
not require the Arbor package split, a native compiler or the v2 scheduler.
No end-of-support date has been set for ExMCP 1.x.

The accumulated compatible additions after 1.5.0 warrant a minor release.
Review the 1.6.0 changelog's **Behavior change** entries: metadata and issuer
validation, linked transport ownership, typed transport errors, inspection
redaction and Claude session MCP capability reporting correct prior behaviour.
The Mint/Cowlib security floors may require updating an older lockfile.

## Backport provenance

| Fix | Origin | 1.x adaptation |
| --- | --- | --- |
| Claude byte caps and UTF-8 response validation | arbor_acp `991fc419` | Mapper and regression/golden tests; original protocol and Port runner |
| ZCode session catalogs, model selection and native setter acknowledgements | arbor_acp `7e299f84` | Adapter mapping plus additive deferred bridge return form and optional failure callback; existing adapter forms still work |
| Complete response fields and native content/accessors | arbor_mcp `24b632f9`, `81c19c3b` | Preserve `to_test_map/1`, local `meta` spelling, omitted local false `isError`, and old facade defaults |
| Correct resource-text extraction | arbor_mcp `24b632f9` | Read standard `contents` without adopting new v2 facade options or errors |

TLS/OS CA deadlines, security dependency floors, client lifecycle and deadline
fixes, credential redaction and private Claude MCP configuration files already
exist on the maintained source line after tag `v1.5.0`; they are included once,
not reapplied as new backports.

## 1.6.1 patch release

1.6.1 is a compatible patch release of correctness and security fixes from the ArborMCP and ArborACP lines. It keeps the 1.6.0 API, configuration and application identity. Before upgrading, review the 1.6.1 changelog's **Behavior change** entries:
- tool error text no longer contains inspected terms;
- the wire field is now `structuredContent`;
- an explicit `nil`/`false` `structuredContent` is now validated;
- the Codex handshake stops when `initialize` fails.

| Fix | Origin | 1.x adaptation |
| --- | --- | --- |
| OAuth `resource` exactly as published in PRM | arbor_mcp `ff9e2f11` | Already on the branch as `2152b2a9` |
| `decimal` 3.1.2 security floor | arbor_mcp `1408e29c` | Already on the branch as `78932fc7` |
| Batch teardown with integer batch IDs | arbor_mcp `e16c0da3` | Batch guard only |
| Reverse-request and MRTR task retirement | arbor_mcp `289f0213` | Written independently, without the v2 Lifetime machinery |
| Legacy HTTP+SSE POST deadlines | arbor_mcp `289f0213` | POST deadlines only |
| ClientConfig transport option forwarding | arbor_mcp `d399e73f` | Forwarding only; no entrypoint consolidation |
| Typed error for non-object `_meta` | arbor_mcp `899a5952` | No notification `_meta` |
| Compatible Streamable HTTP version headers | arbor_mcp `367e151f` | A private conn marker keeps legacy HTTP+SSE exact |
| Canonical `structuredContent` on the wire | arbor_mcp `9ddacfe5` | Wire boundary only; the Tools API return value is unchanged |
| Validation of the emitted `structuredContent` | arbor_mcp `63486d3a` | Validation only |
| `from_file` `:mime_types` enforcement | arbor_mcp `9da48bf2` | Enforcement only |
| Tool error text without `inspect/1` | arbor_mcp `29441805` | Error text only; the 1.x API is kept |
| ReliabilityWrapper closes the wrapped transport | arbor_mcp `939d139c` | Wrapper close only |
| Circuit-breaker execution cutoff | arbor_mcp `7f91271f` | Cherry-picked |
| DETS table names without atoms | arbor_mcp `20d04d9b` | Table names only; on-disk file names unchanged |
| Pi edit snapshots contained to the workspace | arbor_acp#5 `54cb0d40` | Uses `ExMCP.Internal.WorkspacePath` |
| AdapterBridge `session/list` error reply | arbor_acp `f0ba2663` | Bridge clause only |
| Codex requests without `params` | arbor_acp `f0ba2663` | Classification only |
| Codex handshake stops on `initialize` error | arbor_acp `f0ba2663` | No native-API field; golden renamed |

Left out of this patch:
- Tagged schema declaration validation (arbor_mcp `cc1f4cba`). It would reject DSL schemas that 1.6.0 accepts and that work at runtime, including MCP's default 2020-12 `$schema`.
- JSON Schema 2020-12 dialect support. It needs a new dependency and changes how schemas validate, so it belongs in a minor release.
- The ZCode `session/list` error path ([arbor_acp#7](https://github.com/trust-arbor/arbor_acp/issues/7)). It will be fixed on the ArborACP line first and then backported.

## Qualification and publication

Run maintenance CI and adapter/protocol/security regressions on this source.
Check documentation and package contents; install the built archive into a
clean consumer and assemble a release against the unchanged application name.
Only after review and passing CI should the maintenance PR be merged and a
fresh `v1.6.x` tag/package published. Publishing needs a user-owned terminal
for any Hex 2FA prompt. Keep the v2 RC and stable-release gates independent.
