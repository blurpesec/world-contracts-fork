/**
 * Localnet harness: ship <-> storage unit item transfers against the ADR-0004
 * prototype (`experiments/docking/adr`), where:
 *   - `entity::interact` injects no location check,
 *   - `inventory::withdraw` / `deposit` push `Interaction<Docked>` themselves,
 *   - `ProofConfig<Docked>` is either Attested or Signed,
 *   - every player transaction is gas-sponsored.
 *
 * Variants (how each transfer PTB satisfies `Interaction<Docked>`):
 *   T        Attested: `verify_interaction_attested` (allowlisted sponsor, no proof)
 *   A        Signed, ADR as written: a fresh proof per PTB, nonce kept forever
 *   A+prune  as A, then one tx deletes the expired nonces (experiment)
 *   A'       Signed, one proof reused by every PTB, no nonce (experiment)
 *   B2       one `dock` PTB, transfers read a shared `DockSession`, `undock` (experiment)
 *
 * Usage: see experiments/docking/README.md (run via ./experiments/docking/run.sh).
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { bcs } from '@mysten/sui/bcs'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction, type TransactionArgument } from '@mysten/sui/transactions'
import {
  createWorldClient,
  type ExecutedTransaction,
  requireExecutedTx,
} from '../../../sdk/world-sdk/src/client.js'
import { loadWorldConfig } from '../../../sdk/world-sdk/src/config/load.js'
import type { WorldConfig } from '../../../sdk/world-sdk/src/config/types.js'
import {
  addSponsors,
  completeRequest,
  deriveObjectId,
  enableAdminAction,
  mintAccess,
  ownerRequirement,
  verifyOwner,
} from '../../../sdk/world-sdk/src/packages/core.js'
import {
  balanceOf,
  bridgeInRequirement,
  createStorageUnit,
  deposit,
  depositRequirement,
  gameItemToChain,
  withdraw,
  withdrawRequirement,
} from '../../../sdk/world-sdk/src/packages/inventory.js'

// === Parameters ===

const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url))
const DEPLOY_DIR = `${REPO_ROOT}deployments/localnet-adr`
const RESULTS = `${DEPLOY_DIR}/docking-bench.json`
const TRANSFERS = Number(process.env.TRANSFERS ?? 20)
const PLAYERS = Number(process.env.PLAYERS ?? 8)
const CONCURRENT_TRANSFERS = Number(process.env.CONCURRENT_TRANSFERS ?? 10)
const SESSION_SIZES = (process.env.SESSION_SIZES ?? '1,5,20').split(',').map(Number)
const SESSION_TTL_MS = Number(process.env.SESSION_TTL_MS ?? 10 * 60_000)
// Deadline of a per-transfer (A) proof: only has to outlive one transaction.
const PROOF_TTL_MS = Number(process.env.PROOF_TTL_MS ?? 5_000)
// ONLY=session skips the other phases.
const ONLY = process.env.ONLY

const MODULE_ID = 0x51n
const ORE = 77_800n
const VOL = 1n
const STOCK = 100_000n
const SPONSOR_FUNDING_MIST = 5_000_000_000n
const PLAYER_FUNDING_MIST = 500_000_000n
const TENANT = `docking-${Date.now().toString(36)}`
const MODE_ATTESTED = 0
const MODE_SIGNED = 1

type Variant = 'T' | 'A' | 'A+prune' | "A'" | 'B2'
const VARIANTS: Variant[] = ['T', 'A', 'A+prune', "A'", 'B2']
const LABEL: Record<Variant, string> = {
  T: 'T   attested (sponsor)',
  A: 'A   proof per tx (ADR)',
  'A+prune': 'A+p proof per tx, nonces pruned',
  "A'": "A'  one reused proof",
  B2: 'B2  docked session',
}

// === World ===

const config = adrConfig(loadWorldConfig(`${DEPLOY_DIR}/world.json`))
const client = createWorldClient({ config })
const CORE = config.packageOverrides?.core as string
const DOCKED = `${CORE}::interaction_service::Docked`
const ACL = config.sharedObjects.adminAcl.id

const adminKey = process.env.SUI_PRIVATE_KEY
if (!adminKey) throw new Error('SUI_PRIVATE_KEY (the localnet deployer) is required')
const admin = Ed25519Keypair.fromSecretKey(adminKey)
// Stands in for the game server: the only key a Signed config trusts.
const server = new Ed25519Keypair()

/** The SDK resolves `core`/`inventory`; point them at the ADR prototype packages. */
function adrConfig(c: WorldConfig): WorldConfig {
  const o = c.packageOverrides ?? {}
  if (!o.adr_core || !o.adr_inventory) throw new Error('world.json lacks adr_core/adr_inventory')
  return { ...c, packageOverrides: { core: o.adr_core, inventory: o.adr_inventory } }
}

const DockingProof = bcs.struct('DockingProof', {
  creation_id: bcs.Address,
  target: bcs.Address,
  sender: bcs.Address,
  deadline_ms: bcs.u64(),
  nonce: bcs.u64(),
})

interface Pair {
  index: number
  player: Ed25519Keypair
  sponsor: Ed25519Keypair
  ship: string
  structure: string
  shipCap: string
}

interface TxSample {
  digest: string
  latencyMs: number
  computation: bigint
  storage: bigint
  rebate: bigint
  nonRefundable: bigint
  writesProofConfig: boolean
  serverSignatures: number
  gasPayer: 'sponsor' | 'player'
}

interface SignedProof {
  payload: Uint8Array
  sig: Uint8Array
  nonce: bigint
  deadlineMs: number
}

let signedCfg = ''
let attestedCfg = ''
let nextNonce = BigInt(Date.now()) * 1_000n

// === Main ===

async function main() {
  console.log(`tenant ${TENANT}  adr_core ${CORE}`)
  await setupWorld()

  const scenarioCount = SESSION_SIZES.length * sessionScenarios(1).length
  const needed = Math.max(PLAYERS, ONLY === 'session' ? 0 : 2) + scenarioCount
  const pairs: Pair[] = []
  for (let i = 0; i < needed; i++) pairs.push(await setupPair(i))
  console.log(`set up ${pairs.length} ship/storage-unit pairs (sponsored players)`)
  const [core, fresh] = [pairs.slice(0, PLAYERS), pairs.slice(PLAYERS)]

  const out: Record<string, unknown> = {
    ranAt: new Date().toISOString(),
    params: { TRANSFERS, PLAYERS, CONCURRENT_TRANSFERS, SESSION_SIZES, SESSION_TTL_MS, PROOF_TTL_MS },
  }
  out.session = await runSessions(fresh)

  if (ONLY !== 'session') {
    const sequential: Record<string, Awaited<ReturnType<typeof runSequential>>> = {}
    for (const v of VARIANTS) sequential[v] = await runSequential(core[0], v)
    out.sequential = sequential
    out.breakEven = printBreakEven(sequential)
    out.microbench = await runMicrobench(core[0])
    out.checks = await runChecks(core[0], core[1])
    const concurrent: Record<string, unknown> = {}
    for (const v of VARIANTS.filter((x) => x !== 'A+prune')) {
      concurrent[v] = await runConcurrent(core, v)
    }
    out.concurrent = concurrent
  }

  for (const p of pairs) {
    const total = (await readBalance(p.ship)) + (await readBalance(p.structure))
    if (total !== STOCK) throw new Error(`pair ${p.index}: items not conserved (${total})`)
  }
  console.log(`\nitems conserved on all ${pairs.length} pairs (${STOCK} each)`)

  mkdirSync(dirname(RESULTS), { recursive: true })
  writeFileSync(RESULTS, JSON.stringify(out, bigintJson, 2))
  console.log(`results -> ${RESULTS}`)
}

// === Setup ===

async function setupWorld() {
  const tx = new Transaction()
  // bridge_in pushes a sponsor requirement; the unsponsored admin satisfies it as sender.
  addSponsors(tx, config, [admin.toSuiAddress()])
  createConfig(tx, MODE_SIGNED, server.getPublicKey().toRawBytes())
  signedCfg = createdOfType(await exec(admin, tx), '::interaction_service::ProofConfig')

  // In production one ProofConfig<Docked> is switched with `set_mode`; the
  // harness keeps one per mode so variants can run side by side.
  const tx2 = new Transaction()
  createConfig(tx2, MODE_ATTESTED, new Uint8Array())
  attestedCfg = createdOfType(await exec(admin, tx2), '::interaction_service::ProofConfig')
}

function createConfig(tx: Transaction, mode: number, publicKey: Uint8Array) {
  tx.moveCall({
    target: `${CORE}::interaction_service::create_config`,
    typeArguments: [DOCKED],
    arguments: [tx.object(ACL), tx.pure.u8(mode), tx.pure.vector('u8', publicKey)],
  })
}

/** A player, their gas sponsor, their ship (AccessCap) and a public storage unit. */
async function setupPair(index: number): Promise<Pair> {
  const player = new Ed25519Keypair()
  const sponsor = new Ed25519Keypair()
  const shipKey = { id: 70_000n + BigInt(index), tenant: TENANT }
  const structureKey = { id: 80_000n + BigInt(index), tenant: TENANT }
  const ship = deriveObjectId(config, shipKey)
  const structure = deriveObjectId(config, structureKey)

  const create = new Transaction()
  const [s, p] = create.splitCoins(create.gas, [SPONSOR_FUNDING_MIST, PLAYER_FUNDING_MIST])
  create.transferObjects([s], sponsor.toSuiAddress())
  create.transferObjects([p], player.toSuiAddress())
  addSponsors(create, config, [sponsor.toSuiAddress()])
  for (const [key, name] of [
    [shipKey, 'ship'],
    [structureKey, 'storage unit'],
  ] as const) {
    createStorageUnit(create, config, {
      inGameId: key.id,
      tenant: key.tenant,
      componentId: MODULE_ID,
      typeId: 1n,
      name,
      capacity: STOCK * VOL,
    })
  }
  await exec(admin, create)

  const capTx = new Transaction()
  mintAccess(capTx, config, { entity: ship, owner: player.toSuiAddress(), transferable: false })
  const shipCap = createdOfType(await exec(admin, capTx), '::access_cap::AccessCap')

  // Actions declare only ownership and item rules. Docking is not declared:
  // withdraw/deposit push Interaction<Docked> themselves (ADR point 2).
  const actions = new Transaction()
  const sh = actions.object(ship)
  const su = actions.object(structure)
  const any = (fn: typeof withdrawRequirement) => fn(actions, config, MODULE_ID, {})
  enableAdminAction(actions, config, sh, 'bridge_in', [any(bridgeInRequirement)])
  enableAdminAction(actions, config, sh, 'withdraw', [ownerRequirement(actions, config), any(withdrawRequirement)])
  enableAdminAction(actions, config, sh, 'deposit', [ownerRequirement(actions, config), any(depositRequirement)])
  enableAdminAction(actions, config, su, 'withdraw', [any(withdrawRequirement)])
  enableAdminAction(actions, config, su, 'deposit', [any(depositRequirement)])
  const req = interactCall(actions, sh, 'bridge_in')
  gameItemToChain(actions, config, sh, req, { typeId: ORE, quantity: STOCK, volume: VOL })
  completeRequest(actions, config, sh, req)
  await exec(admin, actions)

  return { index, player, sponsor, ship, structure, shipCap }
}

// === Server ===

/** What the game server returns from "is this ship docked here?". */
async function serverSign(pair: Pair, ttlMs = SESSION_TTL_MS): Promise<SignedProof> {
  const nonce = nextNonce++
  const deadlineMs = Date.now() + ttlMs
  const payload = DockingProof.serialize({
    creation_id: pair.ship,
    target: pair.structure,
    sender: pair.player.toSuiAddress(),
    deadline_ms: BigInt(deadlineMs),
    nonce,
  }).toBytes()
  return { payload, sig: await server.sign(payload), nonce, deadlineMs }
}

// === Transfer PTB ===

type Satisfier = (tx: Transaction, req: TransactionArgument) => void
interface Input {
  proof?: SignedProof
  session?: string
  /** Override the ProofConfig (negative checks). */
  cfg?: string
  /** Leave Interaction<Docked> unsatisfied (negative check). */
  skipDocking?: boolean
}

/** Build the docking satisfier for one PTB. Signed variants verify one proof per PTB. */
function satisfier(tx: Transaction, variant: Variant, input: Input): Satisfier {
  if (input.skipDocking) return () => {}
  if (variant === 'T') {
    const cfg = tx.object(input.cfg ?? attestedCfg)
    const acl = tx.object(ACL)
    return (t, req) =>
      t.moveCall({
        target: `${CORE}::interaction_service::verify_interaction_attested`,
        typeArguments: [DOCKED],
        arguments: [req, cfg, acl],
      })
  }
  if (variant === 'B2') {
    const session = tx.object(input.session as string)
    const clock = tx.object.clock()
    return (t, req) =>
      t.moveCall({
        target: `${CORE}::dock_session::verify_docked`,
        arguments: [req, session, clock],
      })
  }
  const proof = input.proof as SignedProof
  const [p] = tx.moveCall({
    target: `${CORE}::interaction_service::${variant === "A'" ? 'verify_docking_reusable' : 'verify_docking'}`,
    arguments: [
      tx.object(input.cfg ?? signedCfg),
      tx.pure.vector('u8', proof.payload),
      tx.pure.vector('u8', proof.sig),
      tx.object.clock(),
    ],
  })
  return (t, req) =>
    t.moveCall({
      target: `${CORE}::interaction_service::verify_interaction`,
      typeArguments: [DOCKED],
      arguments: [req, p],
    })
}

function interactCall(tx: Transaction, entity: TransactionArgument, action: string) {
  return tx.moveCall({
    target: `${CORE}::entity::interact`,
    arguments: [entity, tx.pure.string(action)],
  })
}

/**
 * `count` transfers of 1 ore in one PTB: ship -> storage unit (even i) or back
 * (odd i). The docking check (proof, session or attestation) is shared by all.
 */
function transferTx(pair: Pair, i: number, variant: Variant, input: Input, count = 1): Transaction {
  const tx = new Transaction()
  const satisfy = satisfier(tx, variant, input)
  const ship = tx.object(pair.ship)
  const structure = tx.object(pair.structure)
  const toStructure = i % 2 === 0
  const [from, to] = toStructure ? [ship, structure] : [structure, ship]
  for (let n = 0; n < count; n++) {
    // Requirement order: [Owner], Withdrawal, then the handler-pushed Interaction<Docked>.
    const out = interactCall(tx, from, 'withdraw')
    if (toStructure) verifyOwner(tx, config, out, pair.shipCap)
    const item = withdraw(tx, config, from, out, { typeId: ORE, quantity: 1n })
    satisfy(tx, out)
    completeRequest(tx, config, from, out)

    const into = interactCall(tx, to, 'deposit')
    if (!toStructure) verifyOwner(tx, config, into, pair.shipCap)
    deposit(tx, config, to, into, item)
    satisfy(tx, into)
    completeRequest(tx, config, to, into)
  }
  return tx
}

function dockTx(proof: SignedProof): Transaction {
  const tx = new Transaction()
  tx.moveCall({
    target: `${CORE}::dock_session::dock`,
    arguments: [
      tx.object(signedCfg),
      tx.pure.vector('u8', proof.payload),
      tx.pure.vector('u8', proof.sig),
      tx.object.clock(),
    ],
  })
  return tx
}

function undockTx(session: string): Transaction {
  const tx = new Transaction()
  tx.moveCall({ target: `${CORE}::dock_session::undock`, arguments: [tx.object(session)] })
  return tx
}

function pruneTx(nonces: bigint[]): Transaction {
  const tx = new Transaction()
  tx.moveCall({
    target: `${CORE}::interaction_service::prune_nonces`,
    typeArguments: [DOCKED],
    arguments: [tx.object(signedCfg), tx.pure.vector('u64', nonces), tx.object.clock()],
  })
  return tx
}

// === Running a variant ===

interface VariantRun {
  samples: TxSample[]
  /** Session or cleanup transactions: dock/undock for B2, prune for A+prune. */
  overhead: TxSample[]
}

/** `transfers` transfer PTBs for one pair, plus that variant's overhead txs. */
async function runVariant(pair: Pair, variant: Variant, transfers: number, oneWay = false): Promise<VariantRun> {
  const samples: TxSample[] = []
  const overhead: TxSample[] = []
  const nonces: bigint[] = []
  let session: string | undefined
  let reusable: SignedProof | undefined
  let lastDeadline = 0

  if (variant === 'B2') {
    const res = await timed(pair, dockTx(await serverSign(pair)), 1)
    overhead.push(res.sample)
    session = createdOfType(res.executed, '::dock_session::DockSession')
  }
  if (variant === "A'") reusable = await serverSign(pair)

  for (let i = 0; i < transfers; i++) {
    let proof: SignedProof | undefined
    let sigs = 0
    if (variant === 'A' || variant === 'A+prune') {
      proof = await serverSign(pair, PROOF_TTL_MS)
      nonces.push(proof.nonce)
      lastDeadline = proof.deadlineMs
      sigs = 1
    } else if (variant === "A'") {
      proof = reusable
      sigs = i === 0 ? 1 : 0
    }
    const tx = transferTx(pair, oneWay ? 0 : i, variant, { proof, session })
    samples.push((await timed(pair, tx, sigs)).sample)
  }

  if (session) overhead.push((await timed(pair, undockTx(session), 0)).sample)
  if (variant === 'A+prune' && nonces.length) {
    await waitForChainTime(lastDeadline + 1)
    overhead.push((await timed(pair, pruneTx(nonces), 0)).sample)
  }
  return { samples, overhead }
}

// === Phase: sessions (measured totals) ===

interface Scenario {
  name: string
  run: (p: Pair) => Promise<{ txs: TxSample[]; verifies: number; serverSigs: number }>
}

function sessionScenarios(n: number): Scenario[] {
  const perTx = (v: Variant, verifies: number, serverSigs: number): Scenario => ({
    name: `${LABEL[v]}`,
    run: async (p) => {
      const r = await runVariant(p, v, n, true)
      return { txs: [...r.samples, ...r.overhead], verifies, serverSigs }
    },
  })
  return [
    perTx('T', 0, 0),
    perTx('A', n, n),
    perTx('A+prune', n, n),
    perTx("A'", n, 1),
    perTx('B2', 1, 1),
    {
      name: 'A   all in 1 tx, one proof',
      run: async (p) => {
        const tx = transferTx(p, 0, 'A', { proof: await serverSign(p, PROOF_TTL_MS) }, n)
        return { txs: [(await timed(p, tx, 1)).sample], verifies: 1, serverSigs: 1 }
      },
    },
    {
      name: 'T   all in 1 tx, attested',
      run: async (p) => {
        const tx = transferTx(p, 0, 'T', {}, n)
        return { txs: [(await timed(p, tx, 0)).sample], verifies: 0, serverSigs: 0 }
      },
    },
  ]
}

/**
 * For each session size N: N items moved ship -> storage unit, each scenario on
 * its own fresh pair so all start from the same state. Totals are summed from
 * the executed transactions, overhead included (no extrapolation).
 */
async function runSessions(fresh: Pair[]) {
  const rows = []
  let next = 0
  for (const n of SESSION_SIZES) {
    console.log(`\nsession: ${n} item(s) ship -> storage unit, sponsored (MIST, whole-session totals)`)
    console.log(
      `  ${'scenario'.padEnd(32)} ${'txs'.padStart(3)} ${'verifies'.padStart(8)} ${'srv sigs'.padStart(8)} ` +
        `${'compute'.padStart(11)} ${'non-refund'.padStart(11)} ${'net storage'.padStart(11)} ` +
        `${'C+NR'.padStart(11)} ${'C+net'.padStart(11)}`,
    )
    for (const sc of sessionScenarios(n)) {
      const pair = fresh[next++]
      const before = await readBalance(pair.structure)
      const { txs, verifies, serverSigs } = await sc.run(pair)
      const moved = (await readBalance(pair.structure)) - before
      if (moved !== BigInt(n)) throw new Error(`${sc.name}: moved ${moved}, expected ${n}`)
      const compute = sum(txs.map((t) => t.computation))
      const nonRefundable = sum(txs.map((t) => t.nonRefundable))
      const netStorage = sum(txs.map((t) => t.storage - t.rebate))
      const row = {
        n,
        scenario: sc.name,
        txs: txs.length,
        verifies,
        serverSigs,
        compute,
        nonRefundable,
        netStorage,
        computePlusNonRefundable: compute + nonRefundable,
        computePlusNetStorage: compute + netStorage,
        allSponsored: txs.every((t) => t.gasPayer === 'sponsor'),
        digests: txs.map((t) => t.digest),
      }
      rows.push(row)
      console.log(
        `  ${sc.name.padEnd(32)} ${String(row.txs).padStart(3)} ${String(verifies).padStart(8)} ` +
          `${String(serverSigs).padStart(8)} ${mist(compute)} ${mist(nonRefundable)} ${mist(netStorage)} ` +
          `${mist(row.computePlusNonRefundable)} ${mist(row.computePlusNetStorage)}`,
      )
    }
  }
  return rows
}

// === Phase: sequential per-transfer cost ===

async function runSequential(pair: Pair, variant: Variant) {
  const { samples, overhead } = await runVariant(pair, variant, TRANSFERS)
  const summary = {
    variant: LABEL[variant],
    transfers: samples.length,
    perTransfer: {
      computation: avg(samples.map((s) => s.computation)),
      storage: avg(samples.map((s) => s.storage)),
      rebate: avg(samples.map((s) => s.rebate)),
      nonRefundable: avg(samples.map((s) => s.nonRefundable)),
      net: avg(samples.map(net)),
      latencyMsP50: pct(samples.map((s) => s.latencyMs), 0.5),
    },
    overhead: overhead.map((o) => ({ net: net(o), nonRefundable: o.nonRefundable, computation: o.computation })),
    proofConfigWritesPerTransfer: samples.filter((s) => s.writesProofConfig).length / samples.length,
  }
  if (variant === VARIANTS[0]) {
    console.log(`\nsequential: ${TRANSFERS} alternating transfers on one pair (MIST, mean per transfer)`)
    console.log(
      `  ${'variant'.padEnd(32)} ${'compute'.padStart(11)} ${'storage'.padStart(11)} ${'rebate'.padStart(11)} ` +
        `${'non-refund'.padStart(11)} ${'net'.padStart(11)}  PC-writes  p50ms  overhead txs (net)`,
    )
  }
  const p = summary.perTransfer
  console.log(
    `  ${summary.variant.padEnd(32)} ${mist(p.computation)} ${mist(p.storage)} ${mist(p.rebate)} ` +
      `${mist(p.nonRefundable)} ${mist(p.net)}  ${summary.proofConfigWritesPerTransfer.toFixed(2).padStart(9)}  ` +
      `${String(p.latencyMsP50).padStart(5)}  ${overhead.map((o) => net(o).toLocaleString('en-US')).join(', ') || '-'}`,
  )
  return { summary, samples, overhead }
}

// === Break-even (linear variants only) ===

const MEASURES = {
  // Gas that never comes back: compute plus the non-refundable part of storage.
  'compute + non-refundable': (s: TxSample) => s.computation + s.nonRefundable,
  // Also counts storage locked up for good (unpruned nonces).
  'compute + net storage': net,
} as const

/**
 * cost(v, N) = overhead(v) + N * perTransfer(v), from the sequential phase.
 * A+prune is left out: its prune rebate grows with N, so it isn't linear; the
 * session phase measures it directly.
 */
function printBreakEven(seq: Record<string, { samples: TxSample[]; overhead: TxSample[] }>) {
  const linear: Variant[] = ['T', 'A', "A'", 'B2']
  const out: Record<string, unknown> = {}
  console.log('\nbreak-even: smallest session size N at which B2 costs no more than each alternative')
  for (const [name, m] of Object.entries(MEASURES)) {
    const per = (v: Variant) => avg(seq[v].samples.map(m))
    const fixed = (v: Variant) => sum(seq[v].overhead.map(m))
    const be: Record<string, number | null> = {}
    for (const t of linear.filter((v) => v !== 'B2')) {
      const saving = per(t) - per('B2')
      const f = fixed('B2') - fixed(t)
      be[`B2 vs ${t}`] = saving <= 0n ? null : f <= 0n ? 1 : Number((f + saving - 1n) / saving)
    }
    console.log(
      `  [${name}] per transfer: ${linear.map((v) => `${v} ${per(v)}`).join(', ')}; B2 dock+undock ${fixed('B2')}`,
    )
    console.log(`    ${Object.entries(be).map(([k, v]) => `${k}: ${v ?? 'never'}`).join(' | ')}`)
    out[name] = {
      perTransfer: Object.fromEntries(linear.map((v) => [v, per(v)])),
      b2Fixed: fixed('B2'),
      breakEven: be,
    }
  }
  return out
}

// === Phase: signature microbenchmark ===

/**
 * Compute has a 1000-unit floor per transaction, so a single ed25519 verify in
 * a small PTB costs nothing extra. Simulate K verifies in one PTB (against K
 * no-op calls) to see where verifies start to cost compute.
 */
async function runMicrobench(pair: Pair) {
  const proof = await serverSign(pair)
  const compute = async (k: number, verify: boolean) => {
    const tx = new Transaction()
    tx.setSender(pair.player.toSuiAddress())
    for (let i = 0; i < k; i++) {
      if (verify) {
        tx.moveCall({
          target: `${CORE}::interaction_service::verify_docking_reusable`,
          arguments: [
            tx.object(signedCfg),
            tx.pure.vector('u8', proof.payload),
            tx.pure.vector('u8', proof.sig),
            tx.object.clock(),
          ],
        })
      } else {
        tx.moveCall({ target: `${CORE}::interaction_service::docked_requirement` })
      }
    }
    const res = await client.simulateTransaction({ transaction: tx, include: { effects: true } })
    if (res.FailedTransaction) throw new Error(`microbench k=${k} failed`)
    return BigInt(res.Transaction.effects.gasUsed.computationCost)
  }
  const rows = []
  console.log('\nmicrobench: K signature verifies in one PTB vs K no-op calls (compute, MIST)')
  console.log(`  ${'K'.padStart(4)} ${'verify'.padStart(12)} ${'no-op'.padStart(12)} ${'extra/verify'.padStart(13)}`)
  for (const k of [1, 8, 32, 64, 128, 256, 512]) {
    const v = await compute(k, true)
    const b = await compute(k, false)
    const extra = (v - b) / BigInt(k)
    rows.push({ k, verify: v, noop: b, extraPerVerify: extra })
    console.log(`  ${String(k).padStart(4)} ${mist(v).padStart(12)} ${mist(b).padStart(12)} ${mist(extra).padStart(13)}`)
  }
  return rows
}

// === Phase: correctness ===

async function runChecks(pair: Pair, other: Pair) {
  const results: Record<string, string> = {}
  const expectFail = async (name: string, run: () => Promise<unknown>) => {
    try {
      await run()
      results[name] = 'UNEXPECTED SUCCESS'
    } catch (e) {
      results[name] = `rejected: ${shortError(e)}`
    }
  }

  // Handler-pushed requirement: the transfer can't complete without docking.
  await expectFail('no docking check at all', () =>
    run(pair, transferTx(pair, 0, 'T', { skipDocking: true })),
  )

  // Attested mode.
  await expectFail('T unsponsored player', () =>
    exec(pair.player, transferTx(pair, 0, 'T', {})),
  )
  await expectFail('T sponsor not allowlisted', () =>
    run({ ...pair, sponsor: other.player }, transferTx(pair, 0, 'T', {})),
  )
  await expectFail('T against Signed config', () =>
    run(pair, transferTx(pair, 0, 'T', { cfg: signedCfg })),
  )

  // Signed mode.
  await expectFail('A against Attested config', async () =>
    run(pair, transferTx(pair, 0, 'A', { proof: await serverSign(pair), cfg: attestedCfg })),
  )
  const proof = await serverSign(pair, PROOF_TTL_MS)
  await run(pair, transferTx(pair, 0, 'A', { proof }))
  await expectFail('A replayed proof', () => run(pair, transferTx(pair, 1, 'A', { proof })))
  await expectFail('A proof for another ship', async () =>
    run(other, transferTx(other, 0, 'A', { proof: await serverSign(pair) })),
  )
  await expectFail('A+p prune live nonce', () => run(pair, pruneTx([proof.nonce])))
  await waitForChainTime(proof.deadlineMs + 1)
  await run(pair, pruneTx([proof.nonce]))
  await expectFail('A+p replay after prune', () => run(pair, transferTx(pair, 1, 'A', { proof })))
  await run(pair, transferTx(pair, 1, 'A', { proof: await serverSign(pair) }))

  // Docked session.
  const short = await run(pair, dockTx(await serverSign(pair, 2_000)))
  const expired = createdOfType(short, '::dock_session::DockSession')
  await sleep(4_000)
  await expectFail('B2 expired session', () =>
    run(pair, transferTx(pair, 0, 'B2', { session: expired })),
  )
  await run(pair, undockTx(expired))
  const session = createdOfType(
    await run(pair, dockTx(await serverSign(pair))),
    '::dock_session::DockSession',
  )
  await run(pair, transferTx(pair, 0, 'B2', { session }))
  await expectFail("B2 someone else's session", () =>
    run(other, transferTx(other, 0, 'B2', { session })),
  )
  await expectFail("B2 someone else's undock", () => run(other, undockTx(session)))
  await run(pair, transferTx(pair, 1, 'B2', { session }))
  await run(pair, undockTx(session))
  await expectFail('B2 session after undock', () =>
    run(pair, transferTx(pair, 0, 'B2', { session })),
  )

  console.log('\ncorrectness checks (all should be rejected)')
  for (const [k, v] of Object.entries(results)) console.log(`  ${k.padEnd(30)} ${v}`)
  const bad = Object.entries(results).filter(([, v]) => v === 'UNEXPECTED SUCCESS')
  if (bad.length) throw new Error(`checks passed that should fail: ${bad.map(([k]) => k)}`)
  return results
}

// === Phase: concurrent ===

async function runConcurrent(pairs: Pair[], variant: Variant) {
  const started = performance.now()
  const settled = await Promise.allSettled(pairs.map((p) => runVariant(p, variant, CONCURRENT_TRANSFERS)))
  const wallMs = performance.now() - started
  const done = settled.filter((s): s is PromiseFulfilledResult<VariantRun> => s.status === 'fulfilled')
  const failures = settled
    .filter((s): s is PromiseRejectedResult => s.status === 'rejected')
    .map((s) => shortError(s.reason))
  const latencies = done.flatMap((s) => s.value.samples.map((x) => x.latencyMs))
  const summary = {
    variant: LABEL[variant],
    players: pairs.length,
    transfers: latencies.length,
    wallMs: Math.round(wallMs),
    transfersPerSec: Number(((latencies.length / wallMs) * 1000).toFixed(2)),
    latencyMsP50: pct(latencies, 0.5),
    latencyMsP95: pct(latencies, 0.95),
    failures,
  }
  if (variant === VARIANTS[0]) console.log('\nconcurrent: every pair at once (single-validator localnet; indicative only)')
  console.log(
    `  ${summary.variant.padEnd(32)} ${String(summary.transfers).padStart(4)} tx  ` +
      `${String(summary.wallMs).padStart(6)} ms wall  ${summary.transfersPerSec} tx/s  ` +
      `p50 ${summary.latencyMsP50} ms  p95 ${summary.latencyMsP95} ms` +
      (failures.length ? `  FAILURES ${failures.length}` : ''),
  )
  return summary
}

// === Execution ===

const INCLUDE = { effects: true, events: true, objectTypes: true } as const

/** Unsponsored: `signer` sends and pays. Used for admin setup and negative checks. */
async function exec(signer: Ed25519Keypair, tx: Transaction): Promise<ExecutedTransaction> {
  tx.setSenderIfNotSet(signer.toSuiAddress())
  const bytes = await tx.build({ client })
  return submit(bytes, [(await signer.signTransaction(bytes)).signature])
}

/** Sponsored: the pair's player sends, the pair's sponsor pays gas. */
async function run(pair: Pair, tx: Transaction): Promise<ExecutedTransaction> {
  tx.setSender(pair.player.toSuiAddress())
  tx.setGasOwner(pair.sponsor.toSuiAddress())
  const bytes = await tx.build({ client })
  const signatures = await Promise.all(
    [pair.player, pair.sponsor].map(async (k) => (await k.signTransaction(bytes)).signature),
  )
  return submit(bytes, signatures)
}

/**
 * Execute and wait for the transaction to be finalized. A transaction that gets
 * effects just before a (localnet) epoch change can be dropped at
 * reconfiguration, so if it hasn't landed in time, resubmit the same signed
 * bytes. That's the same digest, so it is idempotent.
 */
async function submit(bytes: Uint8Array, signatures: string[]): Promise<ExecutedTransaction> {
  for (let attempt = 1; ; attempt++) {
    const res = requireExecutedTx(
      await client.executeTransaction({ transaction: bytes, signatures, include: INCLUDE }),
    )
    debug('executed', res.digest, `attempt ${attempt}`)
    try {
      await client.waitForTransaction({ digest: res.digest, timeout: 20_000 })
      return res
    } catch (e) {
      if (attempt >= 3) throw e
      debug('not finalized, resubmitting', res.digest)
    }
  }
}

async function timed(pair: Pair, tx: Transaction, serverSignatures: number) {
  const t0 = performance.now()
  const executed = await run(pair, tx)
  const latencyMs = Math.round(performance.now() - t0)
  const g = executed.effects.gasUsed
  const gasOwner = executed.effects.gasObject?.outputOwner
  const sample: TxSample = {
    digest: executed.digest,
    latencyMs,
    computation: BigInt(g.computationCost),
    storage: BigInt(g.storageCost),
    rebate: BigInt(g.storageRebate),
    nonRefundable: BigInt(g.nonRefundableStorageFee),
    writesProofConfig: executed.effects.changedObjects.some(
      (o) => o.objectId === signedCfg && o.outputState === 'ObjectWrite',
    ),
    serverSignatures,
    gasPayer:
      gasOwner?.$kind === 'AddressOwner' && gasOwner.AddressOwner === pair.sponsor.toSuiAddress()
        ? 'sponsor'
        : 'player',
  }
  return { executed, sample }
}

/**
 * Wait until the on-chain clock has passed `ms`. The localnet clock follows
 * wall time, set per checkpoint, so a small margin covers checkpoint lag.
 */
async function waitForChainTime(ms: number) {
  const margin = 1_500
  const wait = ms + margin - Date.now()
  if (wait > 0) await sleep(wait)
}

function createdOfType(res: ExecutedTransaction, suffix: string): string {
  const id = res.effects.changedObjects.find(
    (o) => o.idOperation === 'Created' && res.objectTypes[o.objectId]?.split('<')[0].endsWith(suffix),
  )?.objectId
  if (!id) throw new Error(`no created object of type *${suffix} in ${res.digest}`)
  return id
}

async function readBalance(entity: string): Promise<bigint> {
  const tx = new Transaction()
  tx.setSender(admin.toSuiAddress())
  balanceOf(tx, config, tx.object(entity), { componentId: MODULE_ID, typeId: ORE })
  const res = await client.simulateTransaction({ transaction: tx, include: { commandResults: true } })
  if (res.FailedTransaction) throw new Error('balance_of simulation failed')
  const rv = res.commandResults[0]?.returnValues[0]
  if (!rv) throw new Error('balance_of returned no value')
  return BigInt(bcs.u64().parse(rv.bcs))
}

// === Reporting ===

function net(s: TxSample): bigint {
  return s.computation + s.storage - s.rebate
}

function sum(xs: bigint[]): bigint {
  return xs.reduce((a, b) => a + b, 0n)
}

function avg(xs: bigint[]): bigint {
  return xs.length ? sum(xs) / BigInt(xs.length) : 0n
}

function pct(xs: number[], p: number): number {
  if (!xs.length) return 0
  const sorted = [...xs].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]
}

function mist(n: bigint): string {
  return n.toLocaleString('en-US').padStart(11)
}

function shortError(e: unknown): string {
  const msg = e instanceof Error ? e.message : String(e)
  const abort = msg.match(/\b(E[A-Z][A-Za-z]+)\b/)?.[1]
  return (abort ?? msg).slice(0, 140).replace(/\s+/g, ' ')
}

function bigintJson(_k: string, v: unknown) {
  return typeof v === 'bigint' ? v.toString() : v
}

function debug(...args: unknown[]) {
  if (process.env.DEBUG) console.error(new Date().toISOString(), ...args)
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
}

await main()
