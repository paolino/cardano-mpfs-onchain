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
  encodeRequestDatum,
  encodeDeleteRequestDatum,
  encodeMintRedeemer,
  encodeMigratingRedeemer,
  encodeBurningRedeemer,
  encodeEndRedeemer,
  encodeModifyRedeemer,
  encodeContributeRedeemer,
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

// Non-empty MPF root after inserting key "42" value "42" (hex "3432"/"3432")
// into an empty trie with an empty proof []. Known from Aiken unit tests.
const MODIFIED_ROOT =
  "484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea";

// Key and value for the Insert operation (hex encoding of UTF-8 "42")
const INSERT_KEY = "3432";
const INSERT_VALUE = "3432";

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

  it("migration preserves non-empty MPF root", async () => {
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

    // --- CREATE REQUEST UTxO ---
    // Send a Request UTxO to the v0 script address with an Insert operation.
    // This creates a pending request to insert key "42" value "42" into the MPF.
    const requestDatum = encodeRequestDatum(
      assetName,
      ownerKeyHash,
      INSERT_KEY,
      INSERT_VALUE,
    );

    const createRequestTx = await lucid
      .newTx()
      .pay.ToContract(
        v0.scriptAddress,
        { kind: "inline", value: requestDatum },
        { lovelace: 2_000_000n },
      )
      .complete(COMPLETE_OPTS);

    const signedRequest = await createRequestTx.sign.withWallet().complete();
    const requestHash = await signedRequest.submit();
    expect(requestHash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Find the Request UTxO (the one without the cage token)
    const v0UtxosAfterRequest = await lucid.utxosAt(v0.scriptAddress);
    const requestUtxo = v0UtxosAfterRequest.find(
      (u) => u.assets[v0Unit] !== 1n && u.datum === requestDatum,
    );
    expect(requestUtxo).toBeDefined();

    // Re-fetch the State UTxO (might have changed index)
    const stateUtxoForModify = v0UtxosAfterRequest.find(
      (u) => u.assets[v0Unit] === 1n,
    );
    expect(stateUtxoForModify).toBeDefined();

    // --- MODIFY on v0 ---
    // Spend State UTxO (Modify redeemer) + Request UTxO (Contribute redeemer)
    // to fold the Insert request into the MPF, producing a non-empty root.
    const modifyRedeemer = encodeModifyRedeemer([[]]);
    const contributeRedeemer = encodeContributeRedeemer(stateUtxoForModify!);
    const modifiedDatum = encodeStateDatum(ownerKeyHash, MODIFIED_ROOT);

    const modifyTx = await lucid
      .newTx()
      .collectFrom([stateUtxoForModify!], modifyRedeemer)
      .collectFrom([requestUtxo!], contributeRedeemer)
      .pay.ToContract(
        v0.scriptAddress,
        { kind: "inline", value: modifiedDatum },
        { [v0Unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.SpendingValidator(v0.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedModify = await modifyTx.sign.withWallet().complete();
    const modifyHash = await signedModify.submit();
    expect(modifyHash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify Modify: State UTxO now has non-empty root
    const v0UtxosAfterModify = await lucid.utxosAt(v0.scriptAddress);
    const modifiedStateUtxo = v0UtxosAfterModify.find(
      (u) => u.assets[v0Unit] === 1n,
    );
    expect(modifiedStateUtxo).toBeDefined();
    // Verify the datum contains the expected non-empty root
    expect(modifiedStateUtxo!.datum).toBe(modifiedDatum);

    // --- MIGRATE v0 -> v1 with non-empty root ---
    const endRedeemer = encodeEndRedeemer();
    const burnRedeemer = encodeBurningRedeemer();
    const migrateV0V1Redeemer = encodeMigratingRedeemer(v0.policyId, assetName);

    // The migration datum carries over the non-empty root
    const migrateDatumV1 = encodeStateDatum(ownerKeyHash, MODIFIED_ROOT);

    const migrateV0V1Tx = await lucid
      .newTx()
      .collectFrom([modifiedStateUtxo!], endRedeemer)
      .mintAssets({ [v0Unit]: -1n }, burnRedeemer)
      .mintAssets({ [v1Unit]: 1n }, migrateV0V1Redeemer)
      .pay.ToContract(
        v1.scriptAddress,
        { kind: "inline", value: migrateDatumV1 },
        { [v1Unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(v0.mintPolicy)
      .attach.MintingPolicy(v1.mintPolicy)
      .attach.SpendingValidator(v0.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedMigrateV0V1 = await migrateV0V1Tx.sign.withWallet().complete();
    const migrateV0V1Hash = await signedMigrateV0V1.submit();
    expect(migrateV0V1Hash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify migration: token exists at v1 with the non-empty root preserved
    const v1Utxos = await lucid.utxosAt(v1.scriptAddress);
    const v1StateUtxo = v1Utxos.find(
      (u) => u.assets[v1Unit] === 1n,
    );
    expect(v1StateUtxo).toBeDefined();
    expect(v1StateUtxo!.datum).toBe(migrateDatumV1);

    // Verify: no token at v0 address
    const v0UtxosAfterMigrate = await lucid.utxosAt(v0.scriptAddress);
    const v0Remaining = v0UtxosAfterMigrate.find(
      (u) => u.assets[v0Unit] === 1n,
    );
    expect(v0Remaining).toBeUndefined();

    // --- DELETE on v1 ---
    // Create a Delete Request to remove the key we inserted on v0.
    // After deletion the MPF root should return to EMPTY_ROOT.
    const deleteRequestDatum = encodeDeleteRequestDatum(
      assetName,
      ownerKeyHash,
      INSERT_KEY,
      INSERT_VALUE,
    );

    const createDeleteTx = await lucid
      .newTx()
      .pay.ToContract(
        v1.scriptAddress,
        { kind: "inline", value: deleteRequestDatum },
        { lovelace: 2_000_000n },
      )
      .complete(COMPLETE_OPTS);

    const signedDeleteReq = await createDeleteTx.sign.withWallet().complete();
    const deleteReqHash = await signedDeleteReq.submit();
    expect(deleteReqHash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Find the Delete Request UTxO and refresh the State UTxO
    const v1UtxosForDelete = await lucid.utxosAt(v1.scriptAddress);
    const deleteRequestUtxo = v1UtxosForDelete.find(
      (u) => u.assets[v1Unit] !== 1n && u.datum === deleteRequestDatum,
    );
    expect(deleteRequestUtxo).toBeDefined();

    const v1StateForModify = v1UtxosForDelete.find(
      (u) => u.assets[v1Unit] === 1n,
    );
    expect(v1StateForModify).toBeDefined();

    // --- MODIFY on v1 (Delete) ---
    // Fold the Delete request into the MPF, returning root to empty.
    const deleteModifyRedeemer = encodeModifyRedeemer([[]]);
    const deleteContributeRedeemer = encodeContributeRedeemer(v1StateForModify!);
    const deletedDatum = encodeStateDatum(ownerKeyHash, EMPTY_ROOT);

    const deleteModifyTx = await lucid
      .newTx()
      .collectFrom([v1StateForModify!], deleteModifyRedeemer)
      .collectFrom([deleteRequestUtxo!], deleteContributeRedeemer)
      .pay.ToContract(
        v1.scriptAddress,
        { kind: "inline", value: deletedDatum },
        { [v1Unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.SpendingValidator(v1.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedDeleteModify = await deleteModifyTx.sign.withWallet().complete();
    const deleteModifyHash = await signedDeleteModify.submit();
    expect(deleteModifyHash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify: root is back to empty after deletion
    const v1UtxosAfterDelete = await lucid.utxosAt(v1.scriptAddress);
    const v1DeletedState = v1UtxosAfterDelete.find(
      (u) => u.assets[v1Unit] === 1n,
    );
    expect(v1DeletedState).toBeDefined();
    expect(v1DeletedState!.datum).toBe(deletedDatum);

    // --- MIGRATE v1 -> v2 with empty root ---
    const v2 = loadValidator(2);
    const v2Unit = v2.policyId + assetName;

    expect(v2.policyId).not.toBe(v0.policyId);
    expect(v2.policyId).not.toBe(v1.policyId);

    const migrateV1V2Redeemer = encodeMigratingRedeemer(v1.policyId, assetName);
    const migrateDatumV2 = encodeStateDatum(ownerKeyHash, EMPTY_ROOT);

    const migrateV1V2Tx = await lucid
      .newTx()
      .collectFrom([v1DeletedState!], endRedeemer)
      .mintAssets({ [v1Unit]: -1n }, burnRedeemer)
      .mintAssets({ [v2Unit]: 1n }, migrateV1V2Redeemer)
      .pay.ToContract(
        v2.scriptAddress,
        { kind: "inline", value: migrateDatumV2 },
        { [v2Unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(v1.mintPolicy)
      .attach.MintingPolicy(v2.mintPolicy)
      .attach.SpendingValidator(v1.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedMigrateV1V2 = await migrateV1V2Tx.sign.withWallet().complete();
    const migrateV1V2Hash = await signedMigrateV1V2.submit();
    expect(migrateV1V2Hash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify: token at v2 with empty root (back to zero)
    const v2Utxos = await lucid.utxosAt(v2.scriptAddress);
    const v2StateUtxo = v2Utxos.find(
      (u) => u.assets[v2Unit] === 1n,
    );
    expect(v2StateUtxo).toBeDefined();
    expect(v2StateUtxo!.datum).toBe(migrateDatumV2);

    // Verify: no token at v1 address
    const v1UtxosFinal = await lucid.utxosAt(v1.scriptAddress);
    const v1Remaining = v1UtxosFinal.find(
      (u) => u.assets[v1Unit] === 1n,
    );
    expect(v1Remaining).toBeUndefined();

    // --- END on v2 ---
    const endV2Tx = await lucid
      .newTx()
      .collectFrom([v2StateUtxo!], endRedeemer)
      .mintAssets({ [v2Unit]: -1n }, burnRedeemer)
      .attach.MintingPolicy(v2.mintPolicy)
      .attach.SpendingValidator(v2.spendValidator)
      .addSignerKey(ownerKeyHash)
      .complete(COMPLETE_OPTS);

    const signedEndV2 = await endV2Tx.sign.withWallet().complete();
    const endV2Hash = await signedEndV2.submit();
    expect(endV2Hash).toBeTruthy();

    await new Promise((r) => setTimeout(r, 5000));

    // Verify cleanup: no token at v2
    const v2UtxosFinal = await lucid.utxosAt(v2.scriptAddress);
    const v2Remaining = v2UtxosFinal.find(
      (u) => u.assets[v2Unit] === 1n,
    );
    expect(v2Remaining).toBeUndefined();
  });
});
