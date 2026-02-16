import { describe, it, expect, beforeAll } from "vitest";
import { createHash } from "node:crypto";
import {
  type LucidEvolution,
  getAddressDetails,
  fromHex,
  toHex,
} from "@lucid-evolution/lucid";
import { waitForYaci, initLucid, createTestWallet } from "./setup.js";
import { loadValidator } from "./blueprint.js";
import {
  encodeStateDatum,
  encodeMintRedeemer,
  encodeMigratingRedeemer,
  encodeBurningRedeemer,
  encodeEndRedeemer,
} from "./codec.js";

// Use Ogmios for script evaluation instead of local UPLC
const COMPLETE_OPTS = { localUPLCEval: false };

// Compute the asset name the same way the validator does:
// SHA2-256(txHash ++ outputIndex as 2 big-endian bytes)
function computeAssetName(txHash: string, outputIndex: number): string {
  const txBytes = fromHex(txHash);
  const idxBytes = new Uint8Array(2);
  idxBytes[0] = (outputIndex >> 8) & 0xff;
  idxBytes[1] = outputIndex & 0xff;
  const combined = new Uint8Array(txBytes.length + 2);
  combined.set(txBytes);
  combined.set(idxBytes, txBytes.length);
  const hash = createHash("sha256").update(combined).digest();
  return toHex(new Uint8Array(hash));
}

// Empty MPF root hash — root(empty) from aiken/merkle_patricia_forestry.
// This is the null_hash constant: 32 bytes of zeros.
const EMPTY_ROOT =
  "0000000000000000000000000000000000000000000000000000000000000000";

describe("MPF Cage Migration E2E", () => {
  let lucid: LucidEvolution;
  let walletAddress: string;
  let ownerKeyHash: string;

  beforeAll(async () => {
    await waitForYaci();
    lucid = await initLucid();
    const wallet = await createTestWallet(lucid);
    walletAddress = wallet.address;
    const details = getAddressDetails(walletAddress);
    ownerKeyHash = details.paymentCredential!.hash;
  });

  it("mint and end on single version", async () => {
    const v0 = loadValidator(0);

    // --- MINT ---
    // Pick a UTxO to consume for uniqueness
    const utxos = await lucid.wallet().getUtxos();
    expect(utxos.length).toBeGreaterThan(0);
    const seedUtxo = utxos[0];

    const assetName = computeAssetName(seedUtxo.txHash, seedUtxo.outputIndex);
    const unit = v0.policyId + assetName;
    const datum = encodeStateDatum(ownerKeyHash, EMPTY_ROOT);
    const mintRedeemer = encodeMintRedeemer(seedUtxo);

    const mintTx = await lucid
      .newTx()
      .collectFrom([seedUtxo])
      .mintAssets({ [unit]: 1n }, mintRedeemer)
      .pay.ToContract(
        v0.scriptAddress,
        { kind: "inline", value: datum },
        { [unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(v0.mintPolicy)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedMint = await mintTx.sign.withWallet().complete();
    const mintHash = await signedMint.submit();
    expect(mintHash).toBeTruthy();

    // Wait for confirmation
    await new Promise((r) => setTimeout(r, 5000));

    // Verify mint
    const scriptUtxos = await lucid.utxosAt(v0.scriptAddress);
    const stateUtxo = scriptUtxos.find(
      (u) => u.assets[unit] === 1n,
    );
    expect(stateUtxo).toBeDefined();

    // --- END ---
    const endRedeemer = encodeEndRedeemer();
    const burnRedeemer = encodeBurningRedeemer();

    const endTx = await lucid
      .newTx()
      .collectFrom([stateUtxo!], endRedeemer)
      .mintAssets({ [unit]: -1n }, burnRedeemer)
      .attach.MintingPolicy(v0.mintPolicy)
      .attach.SpendingValidator(v0.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedEnd = await endTx.sign.withWallet().complete();
    const endHash = await signedEnd.submit();
    expect(endHash).toBeTruthy();

    // Wait for confirmation
    await new Promise((r) => setTimeout(r, 5000));

    // Verify end - no tokens remaining
    const afterUtxos = await lucid.utxosAt(v0.scriptAddress);
    const remaining = afterUtxos.find(
      (u) => u.assets[unit] === 1n,
    );
    expect(remaining).toBeUndefined();
  });

  it("full migration from version 0 to version 1", async () => {
    const v0 = loadValidator(0);
    const v1 = loadValidator(1);

    // Different versions should produce different policy IDs
    expect(v0.policyId).not.toBe(v1.policyId);

    // --- MINT on v0 ---
    const utxos = await lucid.wallet().getUtxos();
    expect(utxos.length).toBeGreaterThan(0);
    const seedUtxo = utxos[0];

    const assetName = computeAssetName(seedUtxo.txHash, seedUtxo.outputIndex);
    const v0Unit = v0.policyId + assetName;
    const v1Unit = v1.policyId + assetName;
    const datum = encodeStateDatum(ownerKeyHash, EMPTY_ROOT);
    const mintRedeemer = encodeMintRedeemer(seedUtxo);

    const mintTx = await lucid
      .newTx()
      .collectFrom([seedUtxo])
      .mintAssets({ [v0Unit]: 1n }, mintRedeemer)
      .pay.ToContract(
        v0.scriptAddress,
        { kind: "inline", value: datum },
        { [v0Unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(v0.mintPolicy)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedMint = await mintTx.sign.withWallet().complete();
    const mintHash = await signedMint.submit();
    expect(mintHash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify mint on v0
    const v0Utxos = await lucid.utxosAt(v0.scriptAddress);
    const v0StateUtxo = v0Utxos.find(
      (u) => u.assets[v0Unit] === 1n,
    );
    expect(v0StateUtxo).toBeDefined();

    // --- MIGRATE v0 -> v1 ---
    // Single atomic transaction:
    // 1. Spend v0 State UTxO with End redeemer
    // 2. Burn v0 token with Burning redeemer
    // 3. Mint v1 token with Migrating redeemer
    // 4. Output to v1 script address with same root
    const endRedeemer = encodeEndRedeemer();
    const burnRedeemer = encodeBurningRedeemer();
    const migrateRedeemer = encodeMigratingRedeemer(v0.policyId, assetName);

    // The output datum for v1 carries over the same root
    const migrateDatum = encodeStateDatum(ownerKeyHash, EMPTY_ROOT);

    const migrateTx = await lucid
      .newTx()
      // Spend v0 state UTxO (End redeemer on spending validator)
      .collectFrom([v0StateUtxo!], endRedeemer)
      // Burn v0 token
      .mintAssets({ [v0Unit]: -1n }, burnRedeemer)
      // Mint v1 token (Migrating redeemer)
      .mintAssets({ [v1Unit]: 1n }, migrateRedeemer)
      // Send new token to v1 script address
      .pay.ToContract(
        v1.scriptAddress,
        { kind: "inline", value: migrateDatum },
        { [v1Unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(v0.mintPolicy)
      .attach.MintingPolicy(v1.mintPolicy)
      .attach.SpendingValidator(v0.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedMigrate = await migrateTx.sign.withWallet().complete();
    const migrateHash = await signedMigrate.submit();
    expect(migrateHash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify migration: token exists at v1 address
    const v1Utxos = await lucid.utxosAt(v1.scriptAddress);
    const v1StateUtxo = v1Utxos.find(
      (u) => u.assets[v1Unit] === 1n,
    );
    expect(v1StateUtxo).toBeDefined();

    // Verify: no token at v0 address
    const v0UtxosAfter = await lucid.utxosAt(v0.scriptAddress);
    const v0Remaining = v0UtxosAfter.find(
      (u) => u.assets[v0Unit] === 1n,
    );
    expect(v0Remaining).toBeUndefined();

    // --- END on v1 ---
    const endV1Tx = await lucid
      .newTx()
      .collectFrom([v1StateUtxo!], endRedeemer)
      .mintAssets({ [v1Unit]: -1n }, burnRedeemer)
      .attach.MintingPolicy(v1.mintPolicy)
      .attach.SpendingValidator(v1.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedEndV1 = await endV1Tx.sign.withWallet().complete();
    const endV1Hash = await signedEndV1.submit();
    expect(endV1Hash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify cleanup
    const v1UtxosFinal = await lucid.utxosAt(v1.scriptAddress);
    const v1Remaining = v1UtxosFinal.find(
      (u) => u.assets[v1Unit] === 1n,
    );
    expect(v1Remaining).toBeUndefined();
  });
});
