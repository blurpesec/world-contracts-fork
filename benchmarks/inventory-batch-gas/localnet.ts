// Full gas summary (computation + storage) for moving N item types between two
// entities, batch vs shared PTB, measured by executing real transactions on a
// localnet. `run.sh` starts the network, publishes core/power/inventory, and
// runs this.
//
// Usage: tsx localnet.ts <rpc-url> <keystore> <publish-dir> <n,n,...>
//   <publish-dir> holds core.json / power.json / inventory.json from
//   `sui client test-publish --json`.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { SuiJsonRpcClient, type SuiTransactionBlockResponse } from '@mysten/sui/jsonRpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction, type TransactionObjectArgument } from '@mysten/sui/transactions';

const [rpc, keystore, publishDir, nsArg] = process.argv.slice(2);
if (!nsArg) throw new Error('usage: tsx localnet.ts <rpc-url> <keystore> <publish-dir> <n,n,...>');
const NS = nsArg.split(',').map(Number);

const MODULE_ID = 0x51;
const GENERATOR_ID = 0x71;
const FUEL_BAY_ID = 0x72;
const FIRST_TYPE = 1000;
const HELD = 5;
const VOL = 2;

const client = new SuiJsonRpcClient({ url: rpc, network: 'localnet' });
const [key] = JSON.parse(readFileSync(keystore, 'utf8')) as string[];
const signer = Ed25519Keypair.fromSecretKey(Buffer.from(key, 'base64').subarray(1));
const me = signer.toSuiAddress();

type Changes = { type: string; packageId?: string; objectType?: string; objectId?: string }[];
const changes = (pkg: string): Changes =>
	JSON.parse(readFileSync(join(publishDir, `${pkg}.json`), 'utf8')).objectChanges;
const packageId = (pkg: string) => changes(pkg).find((c) => c.type === 'published')!.packageId!;
const CORE = packageId('core');
const POWER = packageId('power');
const INVENTORY = packageId('inventory');
const created = (c: Changes, suffix: string) =>
	c.find((o) => o.type === 'created' && o.objectType?.endsWith(suffix))!.objectId!;
const REGISTRY = created(changes('core'), '::object_registry::ObjectRegistry');
const ACL = created(changes('core'), '::admin_service::AdminACL');

async function exec(tx: Transaction): Promise<SuiTransactionBlockResponse> {
	tx.setGasBudget(50_000_000_000);
	const res = await client.signAndExecuteTransaction({
		transaction: tx,
		signer,
		options: { showEffects: true, showObjectChanges: true },
	});
	await client.waitForTransaction({ digest: res.digest });
	if (res.effects?.status.status !== 'success') {
		throw new Error(`tx ${res.digest} failed: ${res.effects?.status.error}`);
	}
	return res;
}

// === Move call helpers ===

type Arg = TransactionObjectArgument;
const call = (tx: Transaction, target: string, args: Arg[] = []) =>
	tx.moveCall({ target, arguments: args });
const none = (tx: Transaction) => tx.pure.option('u64', null);
const verifyAdmin = (tx: Transaction, req: Arg) =>
	call(tx, `${CORE}::admin_service::verify_admin`, [req, tx.object(ACL)]);
const verifySponsor = (tx: Transaction, req: Arg) =>
	call(tx, `${CORE}::admin_service::verify_sponsor`, [req, tx.object(ACL)]);
const complete = (tx: Transaction, e: Arg, req: Arg) =>
	call(tx, `${CORE}::entity::complete_request`, [e, req]);
const interact = (tx: Transaction, e: Arg, name: string) =>
	call(tx, `${CORE}::entity::interact`, [e, tx.pure.string(name)]);
const verifyOwner = (tx: Transaction, e: Arg, req: Arg, cap: Arg) =>
	call(tx, `${CORE}::entity::verify_owner`, [e, req, cap]);
const assertOnline = (tx: Transaction, e: Arg, req: Arg) =>
	call(tx, `${POWER}::grid_load::assert_online`, [e, req, tx.object.clock()]);
const itemReq = (tx: Transaction, fn: string) =>
	call(tx, `${INVENTORY}::inventory::${fn}`, [tx.pure.u64(MODULE_ID), none(tx), none(tx), none(tx)]);

function enable(tx: Transaction, e: Arg, cap: Arg, name: string, reqs: Arg[]) {
	const act = call(tx, `${CORE}::action::new`, [
		tx.makeMoveVec({ type: `${CORE}::requirement::Requirement`, elements: reqs }),
	]);
	const req = call(tx, `${CORE}::entity::enable_action`, [e, tx.pure.string(name), act]);
	verifyOwner(tx, e, req, cap);
	complete(tx, e, req);
}

const owner = (tx: Transaction) => call(tx, `${CORE}::access_cap::owner_requirement`);

// === Setup ===

type Holder = { entity: string; cap: string };

/// A shared entity with a powered inventory holding `n` item types, plus the
/// actions both modes need.
async function setup(n: number, entityKey: number): Promise<Holder> {
	// Admin: claim, install grid / inventory / generator / fuel bay, mint the owner cap, share.
	let tx = new Transaction();
	const [e, newReq] = tx.moveCall({
		target: `${CORE}::entity::new`,
		arguments: [tx.object(REGISTRY), tx.pure.u64(entityKey), tx.pure.string('test')],
	});
	verifyAdmin(tx, newReq);
	complete(tx, e, newReq);
	const installs: [string, Arg[]][] = [
		[`${POWER}::power_grid::install`, [e, tx.object.clock()]],
		[
			`${INVENTORY}::inventory::install`,
			[
				e,
				tx.pure.u64(MODULE_ID),
				tx.pure.u64(1),
				tx.pure.option('string', 'SU-01'),
				tx.pure.u64(1_000_000),
				tx.pure.u64(1),
				call(tx, `${POWER}::power_grid::firm`),
				call(tx, `${POWER}::power_grid::power`),
				tx.pure.u64(0),
				tx.pure.u64(0),
				tx.object.clock(),
			],
		],
		[`${CORE}::entity::mint_access`, [e, tx.pure.address(me), tx.pure.bool(true)]],
		[
			`${POWER}::grid_generator::install`,
			[
				e,
				tx.pure.u64(GENERATOR_ID),
				tx.pure.option('string', null),
				tx.pure.u64(10),
				tx.pure.u64(10),
				tx.pure.u64(1),
				tx.object.clock(),
			],
		],
		[
			`${POWER}::grid_fuel::install`,
			[e, tx.pure.u64(FUEL_BAY_ID), tx.pure.option('string', null), tx.pure.u64(1_000), tx.object.clock()],
		],
	];
	for (const [target, args] of installs) {
		const req = call(tx, target, args);
		verifyAdmin(tx, req);
		complete(tx, e, req);
	}
	call(tx, `${CORE}::entity::share`, [e]);
	const res = await exec(tx);
	const entity = created(res.objectChanges as Changes, '::entity::Entity');
	const cap = created(res.objectChanges as Changes, '::access_cap::AccessCap');

	// Owner: actions, fuel, and bring the grid, generator and inventory online.
	tx = new Transaction();
	const E = tx.object(entity);
	const C = tx.object(cap);
	enable(tx, E, C, 'bridge_in', [owner(tx), itemReq(tx, 'bridge_in_requirement')]);
	enable(tx, E, C, 'withdraw', [owner(tx), itemReq(tx, 'withdraw_requirement')]);
	enable(tx, E, C, 'deposit', [owner(tx), itemReq(tx, 'deposit_requirement')]);
	const many = (fn: string) => [owner(tx), ...Array.from({ length: n }, () => itemReq(tx, fn))];
	enable(tx, E, C, 'withdraw_n', many('withdraw_requirement'));
	enable(tx, E, C, 'deposit_n', many('deposit_requirement'));
	const operateGrid = call(tx, `${POWER}::power_grid::operate_grid_requirement`);
	const depositFuel = call(tx, `${POWER}::power_grid::deposit_fuel_requirement`, [
		tx.pure.vector('u64', []),
		none(tx),
		none(tx),
		none(tx),
		none(tx),
	]);
	for (const [name, r] of [
		['operate_grid', operateGrid],
		['deposit_fuel', depositFuel],
	] as const) {
		const act = call(tx, `${CORE}::action::new`, [
			tx.makeMoveVec({ type: `${CORE}::requirement::Requirement`, elements: [r] }),
		]);
		const req = call(tx, `${CORE}::entity::enable_action`, [E, tx.pure.string(name), act]);
		verifyOwner(tx, E, req, C);
		complete(tx, E, req);
	}
	let req = interact(tx, E, 'deposit_fuel');
	call(tx, `${POWER}::grid_fuel::deposit_fuel`, [
		E,
		req,
		tx.pure.u64(7),
		tx.pure.u64(100),
		tx.pure.u64(90),
		tx.pure.u64(14),
		tx.object.clock(),
	]);
	verifyOwner(tx, E, req, C);
	verifySponsor(tx, req);
	complete(tx, E, req);
	const operations: [string, Arg[]][] = [
		[`${POWER}::power_grid::set_power_grid`, [tx.pure.bool(true)]],
		[`${POWER}::grid_generator::set_generator`, [tx.pure.u64(GENERATOR_ID), tx.pure.bool(true)]],
		[`${POWER}::grid_load::set_desired_state`, [tx.pure.u64(MODULE_ID), tx.pure.bool(true)]],
	];
	for (const [target, args] of operations) {
		req = interact(tx, E, 'operate_grid');
		call(tx, target, [E, req, ...args, tx.object.clock()]);
		verifyOwner(tx, E, req, C);
		complete(tx, E, req);
	}
	await exec(tx);

	// Owner: bridge in `n` types, chunked to stay under the PTB command limit.
	for (let start = 0; start < n; start += 100) {
		tx = new Transaction();
		const E = tx.object(entity);
		const C = tx.object(cap);
		for (let i = start; i < Math.min(n, start + 100); i++) {
			const req = interact(tx, E, 'bridge_in');
			verifyOwner(tx, E, req, C);
			call(tx, `${INVENTORY}::inventory::game_item_to_chain_inventory`, [
				E,
				req,
				tx.pure.u64(FIRST_TYPE + i),
				tx.pure.u64(HELD),
				tx.pure.u64(VOL),
			]);
			verifySponsor(tx, req);
			assertOnline(tx, E, req);
			complete(tx, E, req);
		}
		await exec(tx);
	}
	return { entity, cap };
}

// === Measured transactions ===

/// Move one unit of each of `n` types from `from` to `to`: one withdraw_batch
/// and one deposit_batch.
function batchTx(n: number, from: Holder, to: Holder): Transaction {
	const tx = new Transaction();
	const [A, capA, B, capB] = [from.entity, from.cap, to.entity, to.cap].map((id) => tx.object(id));
	// Admin sender attests docking for the transaction.
	call(tx, `${CORE}::docking::attest`, [tx.object(ACL)]);
	const ids = Array.from({ length: n }, (_, i) => FIRST_TYPE + i);
	let req = interact(tx, A, 'withdraw');
	verifyOwner(tx, A, req, capA);
	const items = call(tx, `${INVENTORY}::inventory::withdraw_batch`, [
		A,
		req,
		tx.pure.vector('u64', ids),
		tx.pure.vector('u64', ids.map(() => 1)),
	]);
	assertOnline(tx, A, req);
	complete(tx, A, req);
	req = interact(tx, B, 'deposit');
	verifyOwner(tx, B, req, capB);
	call(tx, `${INVENTORY}::inventory::deposit_batch`, [B, req, items]);
	assertOnline(tx, B, req);
	complete(tx, B, req);
	return tx;
}

/// The same move as `n` single withdraw calls on one request, then `n` single
/// deposits on another.
function sharedTx(n: number, from: Holder, to: Holder): Transaction {
	const tx = new Transaction();
	const [A, capA, B, capB] = [from.entity, from.cap, to.entity, to.cap].map((id) => tx.object(id));
	call(tx, `${CORE}::docking::attest`, [tx.object(ACL)]);
	let req = interact(tx, A, 'withdraw_n');
	verifyOwner(tx, A, req, capA);
	const items: Arg[] = [];
	for (let i = 0; i < n; i++) {
		items.push(
			call(tx, `${INVENTORY}::inventory::withdraw`, [A, req, tx.pure.u64(FIRST_TYPE + i), tx.pure.u64(1)]),
		);
		assertOnline(tx, A, req);
	}
	complete(tx, A, req);
	req = interact(tx, B, 'deposit_n');
	verifyOwner(tx, B, req, capB);
	for (const item of items.reverse()) {
		call(tx, `${INVENTORY}::inventory::deposit`, [B, req, item]);
		assertOnline(tx, B, req);
	}
	complete(tx, B, req);
	return tx;
}

type Gas = { computation: number; storage: number; rebate: number; nonRefundable: number };

async function measure(tx: Transaction): Promise<Gas> {
	const g = (await exec(tx)).effects!.gasUsed;
	return {
		computation: Number(g.computationCost),
		storage: Number(g.storageCost),
		rebate: Number(g.storageRebate),
		nonRefundable: Number(g.nonRefundableStorageFee),
	};
}

// === Main ===

const fmt = (x: number) => x.toLocaleString('en-US');
const rgp = await client.getReferenceGasPrice();

await (async () => {
	const tx = new Transaction();
	call(tx, `${CORE}::admin_service::add_sponsors`, [tx.object(ACL), tx.pure.vector('address', [me])]);
	await exec(tx);
})();

// Entity keys are unique per registry; offset them so reruns on one network work.
const keyBase = Date.now();
const rows: string[] = [];
for (const [i, n] of NS.entries()) {
	const a = await setup(n, keyBase + 2 * i);
	const b = await setup(n, keyBase + 2 * i + 1);
	for (const [mode, build] of [
		['Batch', batchTx],
		['Shared PTB', sharedTx],
	] as const) {
		// Measure A -> B, then move the units back so the next mode starts
		// from the same state. Balances stay non-zero, so every move mutates
		// existing balance entries on both sides.
		const g = await measure(build(n, a, b));
		await measure(build(n, b, a));
		const net = g.computation + g.storage - g.rebate;
		rows.push(
			`| ${n} | ${mode} | ${fmt(g.computation)} | ${fmt(g.storage)} | ${fmt(g.rebate)} | ${fmt(g.nonRefundable)} | ${fmt(net)} |`,
		);
	}
}

console.log(`Localnet, reference gas price ${rgp}. All figures in MIST.`);
console.log('Net = computation + storage cost - storage rebate.\n');
console.log('| N | Mode | Computation | Storage cost | Storage rebate | Non-refundable | Net |');
console.log('|---|---|---|---|---|---|---|');
for (const row of rows) console.log(row);
