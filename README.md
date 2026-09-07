# Cordis Agent — SML Reference Implementation

> A working supervisor tree with fork / dispose semantics, in ~700 lines of Standard ML.
> **v3** covers the single-process (in-runtime) supervisor tree; **v4** extends the same
> semantics across POSIX processes with `fork(2)` / `setpgid(2)` / `kill(-pgid, SIGTERM)`.

---

## What's in here

```
cordis-project/
├── Makefile                        # build + test + run + clean
├── README.md                       # this file
├── src/
│   ├── cordis-agent-v3.sml         # v3: in-process supervisor tree (450 LoC)
│   └── cordis-cross-process.sml    # v4: cross-process supervisor  (~250 LoC)
├── tests/
│   ├── test-v3.sh                  # assertions over v3's log output
│   └── test-v4.sh                  # assertions over v4's log output
└── examples/
    └── hung-worker.sh              # SIGKILL fallback demonstration
```

Everything is:

- **Zero third-party dependency** — only the SML basis and POSIX
- **Single file per binary** — no build system tricks, no ML preprocessor
- **Verified against 32+ invariants** (see `tests/`)

---

## Quick start

```bash
# 1. Ensure Poly/ML 5.7+ is installed
#    Ubuntu:   sudo apt install polyml
#    macOS:    brew install polyml
#    Verify:   poly --version && polyc --help

# 2. Build both v3 wrapper and v4 native binary
make

# 3. See it work
make run-v3        # 9 phases, 125 log lines, in-process cascade
make run-v4        # fork+exec 3 workers, broadcast SIGTERM, reap

# 4. Run tests
make test
```

If you're on Ubuntu and `polyc` complains about missing `libpolyml.so`, the
Makefile creates the symlink for you (uses `sudo`; comment out if not needed).

---

## Layer A vs Layer B — same semantics, two physical layers

| | **v3 · in-process** | **v4 · cross-process** |
|---|---|---|
| unit of isolation | `scope` (SML record) | POSIX process |
| create | `newScope name parent` | `fork() + setpgid()` |
| dispose | `disposeScope s` | `kill(-pgid, SIGTERM)` + `waitpid` |
| latency | nanoseconds | milliseconds (fork/exec) |
| crash blast radius | whole runtime | one worker |
| enforcement | SML type system | Linux/BSD kernel |
| grace period | N/A (synchronous) | 10s → SIGKILL |

The **invariant is identical**: parent alive ⟹ children alive; parent
dead ⟹ all descendants dead. What changes is *who enforces it* — the
SML runtime or the OS kernel.

---

## v3 — Single-process supervisor tree

Read `src/cordis-agent-v3.sml` top to bottom; the file is organized in
9 stacked layers. The demo (`fun main`) walks 9 phases:

```
PHASE 1 root: install logger
PHASE 2 launch Supervisor (own scope, own children list)
PHASE 3 inspect supervisor tree
PHASE 4 artifacts written so far
PHASE 5 PARTIAL DISPOSE: kill only the 'slow' worker
PHASE 6 spawn a LATE worker under supervisor
PHASE 7 FULL DISPOSE: kill the supervisor
PHASE 8 verify: tools retracted, root still healthy
PHASE 9 dispose root (final)
```

Key surfaces:

```sml
(* create a child scope; returns a handle that can kill just that subtree *)
val fork : ctx -> string -> childHandle

(* one call, whole subtree — bottom-up, post-order *)
val disposeScope : scope -> unit

(* generative functor: two instances have DIFFERENT compile-time types *)
functor MakeToolSlot (S : TOOL_SPEC) : sig
  type impl = { invoke : S.input -> S.output }
  exception Box of impl
  val provide : impl -> (unit -> unit)
  val get     : unit -> impl option
end
```

Full walkthrough: `../cordis-agent-v3-README.md` (11 chapters, 2 appendices).

### Optional: drive the supervisor from a real LLM gateway

`scriptedNext` is the default. The same ReAct `runReasoner` can instead be
driven by a real OpenAI-compatible `/chat/completions` endpoint via
`llmNext` (section 6b in `src/cordis-agent-v3.sml`). It stays **pure SML +
POSIX** — the HTTP call is a one-shot `fork` + `exece` of `curl` writing to
a temp file (the v4 trick, so no GC threads leak into the child), and the
response is parsed back into an `action`.

Enable it with environment variables (never hardcoded):

```bash
# The platform's auth token (this is the "authtopic" value). Falls back to
# AUTH_TOPIC if ANTHROPIC_AUTH_TOKEN is unset.
export ANTHROPIC_AUTH_TOKEN=<your-platform-token>
export ANTHROPIC_BASE_URL=https://llm-api.mcisaas.com   # your endpoint base
export CORDIS_LLM_MODEL=claude-opus-5                     # optional model id
make run-v3-llm                                         # CORDIS_LLM_REAL=1 set for you
```

The model answers with one directive line, which `parseDirective` turns
back into an `action`:

```
THOUGHT:    <text>            -> Thought
CALL_TOOL:  <name>|<arg>      -> CallTool   (one `|`; extras fall back to Thought)
LOAD:       <name>            -> LoadTool
FINISH:     <reason>          -> Finish     (also the fallback if parsing fails)
```

Without `ANTHROPIC_AUTH_TOKEN` (or `AUTH_TOPIC`) and `ANTHROPIC_BASE_URL`
set, `llmEnabled` stays off and the original scripted demo runs unchanged
— the real-LLM path is inert and
`make test` is unaffected.

---

## v4 — Cross-process supervisor tree

Same semantics, but every "agent" is now a real OS process.

### Design decision: fork + execve (not fork alone)

Poly/ML pools GC threads. Calling `Posix.Process.fork` from a running
Poly/ML image inherits those threads into the child, which then hangs.
The portable fix used by systemd, docker-runc and every other real
supervisor is:

1. `fork()`
2. In the child: **`execve()` a fresh binary**, replacing the address
   space entirely — no shared GC threads, no leaked handles.
3. Same binary is fine: dispatch on `CORDIS_MODE=supervisor|worker`.

```sml
(* excerpt from src/cordis-cross-process.sml *)
case Posix.Process.fork () of
    NONE => (* CHILD *)
      ( Posix.ProcEnv.setpgid { pid = NONE, pgid = NONE }
      ; Posix.Process.exece
          (self, [self, name],
           ["CORDIS_MODE=worker",
            "CORDIS_NAME=" ^ name,
            ...]) )
  | SOME pid => (* PARENT *)
      ( Posix.ProcEnv.setpgid
          { pid = SOME pid, pgid = SOME (Posix.ProcEnv.getpid ()) }
      ; children := { name = name, pid = pid } :: !children )
```

### The one broadcast pitfall

`kill(-pgid, SIGTERM)` sends to *every* process in the group **including
the sender**. Real supervisors either install `SIG_IGN` on the parent
first, or iterate over tracked child pids. Poly/ML 5.7 does not expose
`sigaction`, so this reference uses the pid-iteration approach:

```sml
List.app (fn c =>
  Posix.Process.kill (Posix.Process.K_PROC (#pid c), Posix.Signal.term))
  (!children)
```

Semantically equivalent, one syscall per child instead of one for the
group. In a production Rust/OCaml port, install the handler and use the
group form.

### The grace period contract

```
t+0     parent sends SIGTERM to each child pid
t+200ms first waitpid_nh() poll
t+400ms second poll ...
t+1s    grace expires — if any child still alive, broadcast SIGKILL
t+1.2s  second-round reap, no zombies allowed
```

Tuning: `gracefulShutdown 5` in `runSupervisor` = 5 × 200ms = 1s. Kubernetes
default is 30s. Change per your workload's flush requirements.

---

## Tests

`make test` runs both v3 and v4 through their demos and greps the log
output for 32+ invariants:

### v3 (29 assertions)
- 4 forks succeeded (math, research, slow, late)
- 3 tools provided (calc@v1, search@v1, write@v1)
- Math computed 7*8=56
- Partial dispose: slow dies, siblings survive
- Cascade dispose: all children dead, logger survives
- No uncaught exceptions

### v4 (17 assertions)

- All 4 phases reached
- Exactly 3 forks
- Each worker booted via exec
- Broadcast reached 3 children
- All 3 reaped (no zombies)
- Graceful shutdown succeeded

If any assertion fails, `make test` exits non-zero with the failing
pattern printed.

---

## Extending

To add a tool: 3 steps in `cordis-agent-v3.sml` — spec struct →
provider plugin → `AList.put toolRegistry (...)`. See the README's
Extension Guide.

To port to Rust/OCaml: the whole file is a Rust module boundary. The
tricky pieces are:

- `disposeScope`: recursive walk. Rust's `Drop` gives you this for free
  if you use `Arc<Scope>` with children as `Vec<Arc<Scope>>`.
- Generative functor: use `PhantomData<S>` + zero-sized types.
- Reactive `Svc.provide`: `tokio::sync::watch` is the closest analog.

---

## References

- Field Manual №03 — visual walkthrough of scope-tree semantics
- Field Manual №04 — visual walkthrough of process-tree semantics
- `cordis-agent-v3-README.md` — 11-chapter code walkthrough of v3

---

## License

Public domain / CC0. This is reference material — copy freely.

*Verified on Poly/ML 5.7.1, Linux 6.x. macOS support: fork/exec/pgid are
identical; the Makefile's `libpolyml.so` symlink step is Linux-specific.*
