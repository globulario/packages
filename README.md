Globular V1 Test Plan
0. V1 validation goal

Globular V1 is validated when all of the following are true:

documented core features are present in the running system
the control plane converges correctly from cold boot
package publishing and deployment work end to end
role/security boundaries are enforced in runtime
common failures are detected, surfaced, and handled safely
destructive recovery workflows are reproducible and auditable
the same tests can run repeatedly in Docker without drift or hidden manual state
1. Test philosophy

Use a four-layer pyramid:

L1. Static / invariant checks

Fast checks that validate structure before runtime.
Examples:

proto authz coverage
generated permissions completeness
package structure
workflow YAML validity
no forbidden raw path auth regressions
no forbidden exec boundaries in controller/node-agent
L2. Functional integration tests

Does the feature work at runtime?
Examples:

service registration
workflow execution
repository publish/install
RBAC authz resolution
DNS records present
health APIs return expected values
L3. Convergence and resilience tests

Does the cluster behave correctly when assumptions break?
Examples:

service stopped
package drift
stale desired state
leader failover
temporary Scylla outage
MinIO unavailable
node agent restart
L4. Recovery and endurance tests

Can the system survive real incidents, explain them, and return to a stable state?
Examples:

node full reseed
backup + restore
repeated long-running workload stability
multiple failure drills in one run
resume / blocked / retry semantics
2. Test environments
Environment A. Docker simulation cluster

Primary V1 proving ground.

Use the existing quickstart as the base and extend it.

Target topology
5 Globular nodes
1 ScyllaDB sidecar or external DB container
systemd inside each node container
real TLS/PKI
real etcd
real MinIO
real workflow execution
real controller / node-agent / repository / RBAC / DNS / monitoring
Why this is the main environment

It gives:

cold boot every run
no hidden bare-metal state
reproducible reset
CI suitability
safe chaos injection
fast iteration
Environment B. Real-cluster truth exam

Not for every test, only for final certification of selected scenarios.

Use it for:

systemd reality
real network/SAN behavior
real disk/package flows
real node reprovision
final backup/restore proof
real day-0/day-1/day-2 flows
Promotion rule

A capability is “V1 certified” only after:

it passes in Docker
and key representative scenarios pass on real cluster
3. Test tracks
Track A. Documentation-to-runtime parity

This is your “run as expected” track.

Goal: prove that documented features are not fiction.

A1. Build the feature inventory

Create a manifest from:

docs
proto services
tasks
operator guides
developer guides
current known issues

Each feature in the manifest should have:

feature name
source doc/proto
runtime owner service
validation test
expected output
maturity status: supported / experimental / known gap
A2. Validate all documented core surfaces

For each documented capability, assert:

the service is deployed
the RPC/CLI exists
the service registers correctly
the health path works
the documented behavior matches runtime
Required coverage

At minimum:

authentication
RBAC
resource
repository
workflow
cluster controller
node agent
DNS
discovery
monitoring
event
file/media/search/title/log where documented
backup manager
AI services
publishing/deployment flows
node recovery flows
Deliverable

A generated V1 runtime parity report:

documented
implemented
running
healthy
tested
mismatched
intentionally deferred

This report becomes one of your strongest assets.

Track B. Cold boot and baseline convergence

Goal: prove the cluster comes up from zero and reaches a correct stable state.

Test cases
Cold boot from empty state
all containers start from clean volumes
etcd initializes
Scylla becomes ready
services register
node agents heartbeat
profiles derive
DNS records appear
workflow service executes initial reconciliation
cluster reaches healthy or explainably degraded steady state
Restart whole cluster
stop all nodes
restart all nodes
no stale poisoned state
no broken service registration
no dead control plane
Partial start order permutations
Scylla delayed
MinIO delayed
controller delayed
node agents before controller
Envoy/xDS reordered
Assertions
convergence completes within bounded time
no infinite reconcile storm
no hidden dependency deadlocks
all critical services become healthy
workflow storage/history exists and is coherent
Track C. Service/API health matrix

Goal: verify every runtime service works and is healthy, not merely running.

Per service, validate
systemd unit active
process reachable
TLS/auth works
health/readiness endpoint or equivalent RPC works
service is discoverable in etcd/discovery
expected DNS/service identity exists
one representative RPC succeeds
one denied RPC is denied correctly where applicable
Per critical service include deep health
repository: read/list/search artifact metadata
workflow: create/list/get run
RBAC: resolve/check an action
cluster-controller: list nodes / desired state read
node-agent: status + package list/report
DNS: A and SRV records correct
monitoring: targets/rules/alerts path live
event: publish + consume one known event
backup: create/list/inspect one backup job
Track D. Package publishing and deployment

Goal: prove the package model end to end.

D1. Service package publish path

Test:

build service package
validate archive structure
publish through CLI/gRPC
repository stores object in MinIO
manifest written
build_id assigned
checksum computed
lifecycle transitions correct
package becomes installable
D2. Deployment/install path

Test:

set desired state or install via supported flow
controller resolves artifact
node agent downloads package
installs binary/unit/config
installed state updates
service starts
service registers
health becomes good
D3. Lifecycle controls

Test:

deprecate
yank
quarantine
revoke
same version different digest rejected
higher version monotonicity enforced
corrupted entrypoint checksum detected
D4. Upgrade/downgrade behavior

Test:

publish v1 then v2
promote/install v2
verify drift clears
if pinning is supported, install explicit old version
verify exact build_id semantics
D5. Negative publish tests
wrong publisher identity
malformed spec
missing bin/
missing specs/
checksum mismatch
unsupported state transition
unauthorized publish attempt
Track E. Workflow and orchestration correctness

Goal: prove workflow is the real execution spine.

E1. Execution basics
launch workflow
steps persist
events persist
callbacks reach actors
history can be read
status transitions are correct
E2. Resume/retry behavior
kill executor mid-step
verify claim/reclaim works
verify skip/re-execute/block decision is correct
no duplicate unsafe side effects
onFailure path works
E3. Receipt-driven behavior

Pick 2–3 real steps and prove:

receipt present -> skip safely
no receipt -> rerun if policy says so
ambiguous verification -> block safely
E4. Blocked workflow UX
induce blocked state
doctor surfaces it
reason is visible
operator can approve/remediate/cancel
workflow resumes correctly
E5. Representative workflows to test
cluster.reconcile
node.join
release.apply.infrastructure
node.repair
node.recover.full_reseed
doctor/remediation workflow
one publish/deploy workflow if workflow-driven
Track F. Security and RBAC enforcement

Goal: prove the new security model lives in runtime.

F1. Authn/authz chain

Validate:

JWT tokens valid
service identity resolved
interceptor chain active
RPC maps to semantic action
role grants action
deny path returns correctly
F2. Permission generation chain

Validate:

proto annotations complete
permissions.generated.json complete
packaged into service artifact
deployed into runtime policy directory
runtime loaded it
semantic mapping works for real RPCs
F3. Role tests

For each real role:

viewer
operator
admin
controller SA
node-agent SA
workflow writer SA
AI service roles
publisher role
bootstrap/break-glass identities

Test:

allowed actions succeed
forbidden actions fail
no hidden wildcard rescue path
path fallback only where expected during migration
F4. Bootstrap lane

Validate:

valid bootstrap window + allowed subject passes
expired denied
missing file denied
invalid subject denied
bootstrap not used once normal role path exists
every bootstrap allow/deny logged
F5. Adversarial tests
forged service account name
unauthorized publish
unauthorized desired-state mutation
unauthorized workflow cancel/retry
unauthorized repository lifecycle mutation
empty token / wrong domain / stale token
raw path wildcard no longer sufficient for migrated services
Track G. Robustness and failure drills

Goal: prove the system behaves well when reality is rude.

G1. Service failure drills

Start with the existing stopped-service drill and expand.

Scenarios:

stop non-critical service
crash service process
restart flapping service
break registration but keep process active
make service active but unhealthy

Validate:

doctor detects
finding categorized correctly
structured action exists where expected
remediation executes
convergence verified truthfully
G2. Infra degradation drills

Scenarios:

temporary Scylla outage
temporary MinIO outage
temporary DNS outage
xDS restart before Envoy
etcd member delayed or temporarily unavailable

Validate:

no silent corruption
degraded state visible
retries bounded
services recover or block safely
no poisoned permanent state
G3. Control-plane drills

Scenarios:

kill leader during active workflow
restart controller during reconciliation
restart workflow service during run
restart node-agent mid-apply
leader failover during package rollout

Validate:

no duplicate execution
workflow ownership moves correctly
no orphaned run
eventual stable convergence or safe block
G4. Network drills

In Docker, inject:

latency
packet loss
partition between subsets
DNS resolution break
controller unreachable from one node
one compute node isolated

Validate:

state truth remains honest
stale data marked stale
no false “healthy”
recovery after partition heal
Track H. Node lifecycle and recovery

Goal: prove nodes can join, drift, fail, and come back correctly.

H1. Node join
fresh node comes online
bootstrap works
identity issued
profiles assigned
packages applied
node reaches workload_ready
H2. Drift and repair
manually remove a package
change installed version
break unit file
corrupt one artifact on disk

Validate:

drift detected
repair selected correctly
node converges back
H3. Full reseed recovery

Use the documented phase model:

precheck
snapshot
fence
drain
await reprovision
await rejoin
reseed artifacts
verify artifacts
verify runtime
unfence
complete

Tests:

dry-run plan
full happy path
missing build_id in exact replay -> reject
resume from mid-reseed
failed verification -> stay fenced
quorum safety warning/block behavior
forced recovery path
H4. Ghost/stale node cleanup
dead node remains in state
cleanup path removes stale installed records
controller remains consistent
Track I. Backup and restore

Goal: prove recoverability, not just backups in theory.

I1. Backup create/list/inspect
create backup
inspect metadata
verify retention/schedule if implemented
verify backup artifact integrity
I2. Restore drills

Use Docker first:

restore repository metadata only
restore RBAC/policy only
restore cluster state and verify services converge
restore after node loss
I3. Disaster scenario
create known good baseline
inject damage
perform restore
verify cluster returns to defined state
verify audit trail captures it

This is one of the most important tracks for commercial trust.

Track J. Observability, diagnosis, and truthfulness

Goal: prove the system tells the truth.

J1. Health/reporting truthfulness
if cache stale, report stale
if service running but not registered, say so
if data unavailable, say inconclusive, not healthy
if workflow blocked, surface blocked, not pending forever
J2. Doctor integration
doctor cluster
doctor service
doctor findings
doctor remediation
doctor blocked workflow surfacing
doctor integration with systemd, repository, workflow, node state
J3. Auditability

For privileged actions, ensure logs/events/history exist:

publish package
desired-state mutation
workflow cancel/retry
node recovery
backup restore
bootstrap allow
break-glass use
Track K. Endurance and repeatability

Goal: prove the cluster does not only survive one pretty run.

K1. Repeated cold-boot cycles
20+ full fresh boot cycles
collect time-to-converge stats
detect flakiness
K2. Long-haul soak
12h / 24h run in Docker
periodic health sampling
background workflows
metrics collection
no memory leak / retry storm / repeated drift
K3. Chaos batch
several controlled drills in sequence
ensure cluster still returns to usable steady state
4. Test suites to build
Suite 1. Smoke

Runs on every PR or local fast pass.
Covers:

static invariants
package validation
one-node or reduced cluster smoke
critical service health
one workflow
one RBAC allow/deny
Suite 2. Functional

Runs on merge or nightly.
Covers:

full 5-node cold boot
parity report
publish/install path
core service matrix
basic recovery drills
Suite 3. Resilience

Nightly or pre-release.
Covers:

failover
outages
network faults
blocked/resume
service stop/crash drills
Suite 4. Recovery certification

Pre-release gate.
Covers:

full reseed
backup/restore
disaster simulation
strict RBAC semantics
package lifecycle hard cases
Suite 5. Soak

Weekly or release candidate.
Covers:

repeated boot cycles
long run
repeated workflow execution
repeated remediation drills
5. Docker implementation plan
Phase 1. Extend the quickstart harness

Add:

scenario runner container or host-side orchestrator
test fixtures for package publish/install
fault injection helpers
network shaping helpers
log/event collector
readiness waiters
metrics snapshotter
Phase 2. Build a machine-readable scenario format

Use YAML for drills, similar to your existing drill file.

Each scenario should define:

name
preconditions
baseline checks
fault injection
expected findings
expected workflow/recovery path
pass/fail criteria
cleanup
Phase 3. Add a cluster probe toolkit

Commands/helpers for:

service health
workflow status
doctor findings
repository artifacts
node status
RBAC decision checks
DNS lookups
event stream
metrics query
Phase 4. Add golden reports

Persist for each run:

converge timeline
service matrix
workflow timeline
findings/remediation summary
RBAC decision report
publish/install trace
recovery trace

That gives you evidence, not only console output.

6. Exit criteria for Globular V1

I would not declare V1 validated until these pass:

Required green gates
cold boot full convergence
runtime parity report for documented core features
core service/API health matrix
publish service package end-to-end
install/upgrade package end-to-end
semantic RBAC enforcement tests
one full stopped-service remediation drill
controller/workflow failover drill
node join drill
full reseed recovery drill
backup create + restore drill
24h soak with no convergence storm
Allowed amber items
documented known gaps explicitly marked
non-built services like compute excluded from runtime parity, but shown as “documented design only”
missing CLI wrappers allowed only if gRPC/MCP path exists and docs say so
Release blockers
silent authz fallback
package publish/install nondeterminism
recovery leaves node unfenced after failed destructive path
workflow resume duplicates unsafe side effects
doctor reports false healthy during degraded conditions
backup restore unproven
cluster requires hidden manual steps not captured in docs
7. Deliverables

The V1 test effort should produce these artifacts:

1. V1 feature parity matrix

Documented feature -> runtime proof -> status

2. Service health certification matrix

Service -> deployed -> healthy -> tested RPC -> authz checked

3. Package lifecycle report

Publish/install/upgrade/lifecycle mutation proof

4. Security enforcement report

Semantic auth chain, role checks, fallback usage, bootstrap usage

5. Recovery playbook evidence

Node reseed trace, backup/restore trace, blocked workflow trace

6. Failure drill catalog

Reusable YAML drills and expected outcomes

7. Release certification summary

Single pass/fail release document for V1

8. Suggested execution order

Do it in this order so you get signal fast:

Wave 1. Baseline truth
cold boot
service matrix
parity report
one publish/install path
one workflow execution path
Wave 2. Security
RBAC enforcement
bootstrap lane
service identity role tests
unauthorized mutation tests
Wave 3. Convergence
service stop/crash
controller restart
workflow resume
Scylla/MinIO temporary outage
Wave 4. Recovery
node join
node drift repair
full reseed
backup/restore
Wave 5. Endurance
repeated boot cycles
soak
chaos batch