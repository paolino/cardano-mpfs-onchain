import { createHash } from "node:crypto";
import { expect } from "vitest";
import {
  type LucidEvolution,
  type UTxO,
  fromHex,
  toHex,
} from "@lucid-evolution/lucid";
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

const COMPLETE_OPTS = { localUPLCEval: false };

const EMPTY_ROOT =
  "0000000000000000000000000000000000000000000000000000000000000000";

/** Return type of `loadValidator`. */
export type Validator = ReturnType<
  typeof import("./blueprint.js").loadValidator
>;

interface PendingRequest {
  utxo: UTxO;
  datum: string;
  fee: bigint;
  lovelace: bigint;
}

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

/**
 * Fluent builder for MPF Cage E2E test scenarios.
 *
 * Each method appends an async step to an internal promise chain.
 * The class implements `PromiseLike` so `await cage(...).mint().end()`
 * triggers the whole chain.
 */
class Cage implements PromiseLike<void> {
  private lucid: LucidEvolution;
  private ownerKeyHash: string;
  private walletAddress: string;
  private validator: Validator;

  private assetName = "";
  private unit = "";
  private stateUtxo: UTxO | undefined;
  private root = EMPTY_ROOT;
  private maxFee = 0n;
  private pendingRequests: PendingRequest[] = [];

  private chain: Promise<void>;

  constructor(
    lucid: LucidEvolution,
    validator: Validator,
    ownerKeyHash: string,
    walletAddress: string,
  ) {
    this.lucid = lucid;
    this.validator = validator;
    this.ownerKeyHash = ownerKeyHash;
    this.walletAddress = walletAddress;
    this.chain = Promise.resolve();
  }

  // --- PromiseLike ---

  then<TResult1 = void, TResult2 = never>(
    onfulfilled?:
      | ((value: void) => TResult1 | PromiseLike<TResult1>)
      | null,
    onrejected?:
      | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
      | null,
  ): Promise<TResult1 | TResult2> {
    return this.chain.then(onfulfilled, onrejected);
  }

  // --- Public DSL methods ---

  mint(opts?: { maxFee?: bigint }): this {
    this.chain = this.chain.then(() => this.doMint(opts));
    return this;
  }

  request(key: string, value: string, opts?: { fee?: bigint }): this {
    this.chain = this.chain.then(() =>
      this.doRequest(key, value, false, opts),
    );
    return this;
  }

  deleteRequest(
    key: string,
    value: string,
    opts?: { fee?: bigint },
  ): this {
    this.chain = this.chain.then(() =>
      this.doRequest(key, value, true, opts),
    );
    return this;
  }

  modify(newRoot: string): this {
    this.chain = this.chain.then(() => this.doModify(newRoot));
    return this;
  }

  migrateTo(newValidator: Validator): this {
    this.chain = this.chain.then(() => this.doMigrate(newValidator));
    return this;
  }

  end(): this {
    this.chain = this.chain.then(() => this.doEnd());
    return this;
  }

  // --- Private step implementations ---

  private async doMint(opts?: { maxFee?: bigint }): Promise<void> {
    this.maxFee = opts?.maxFee ?? 0n;

    const utxos = await this.lucid.wallet().getUtxos();
    expect(utxos.length).toBeGreaterThan(0);
    const seedUtxo = utxos[0];

    this.assetName = computeAssetName(
      seedUtxo.txHash,
      seedUtxo.outputIndex,
    );
    this.unit = this.validator.policyId + this.assetName;
    this.root = EMPTY_ROOT;

    const datum = encodeStateDatum(
      this.ownerKeyHash,
      EMPTY_ROOT,
      this.maxFee,
    );
    const redeemer = encodeMintRedeemer(seedUtxo);

    const tx = await this.lucid
      .newTx()
      .collectFrom([seedUtxo])
      .mintAssets({ [this.unit]: 1n }, redeemer)
      .pay.ToContract(
        this.validator.scriptAddress,
        { kind: "inline", value: datum },
        { [this.unit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(this.validator.mintPolicy)
      .addSignerKey(this.ownerKeyHash)
      .complete(COMPLETE_OPTS);

    await this.submitAndWait(tx);
    this.stateUtxo = await this.findStateUtxo();
  }

  private async doRequest(
    key: string,
    value: string,
    isDelete: boolean,
    opts?: { fee?: bigint },
  ): Promise<void> {
    const fee = opts?.fee ?? 0n;
    const lovelace = 2_000_000n;
    const encode = isDelete
      ? encodeDeleteRequestDatum
      : encodeRequestDatum;
    const datum = encode(
      this.assetName,
      this.ownerKeyHash,
      key,
      value,
      fee,
    );

    const tx = await this.lucid
      .newTx()
      .pay.ToContract(
        this.validator.scriptAddress,
        { kind: "inline", value: datum },
        { lovelace },
      )
      .complete(COMPLETE_OPTS);

    await this.submitAndWait(tx);

    // Find the request UTxO
    const scriptUtxos = await this.lucid.utxosAt(
      this.validator.scriptAddress,
    );
    const requestUtxo = scriptUtxos.find(
      (u) => u.assets[this.unit] !== 1n && u.datum === datum,
    );
    expect(requestUtxo).toBeDefined();

    // Refresh state UTxO (index may have changed)
    this.stateUtxo = await this.findStateUtxo();

    this.pendingRequests.push({
      utxo: requestUtxo!,
      datum,
      fee,
      lovelace,
    });
  }

  private async doModify(newRoot: string): Promise<void> {
    const proofs = this.pendingRequests.map(() => [] as unknown[]);
    const modifyRedeemer = encodeModifyRedeemer(proofs);
    const contributeRedeemer = encodeContributeRedeemer(this.stateUtxo!);
    const newDatum = encodeStateDatum(
      this.ownerKeyHash,
      newRoot,
      this.maxFee,
    );

    let txBuilder = this.lucid
      .newTx()
      .collectFrom([this.stateUtxo!], modifyRedeemer)
      .collectFrom(
        this.pendingRequests.map((r) => r.utxo),
        contributeRedeemer,
      )
      .pay.ToContract(
        this.validator.scriptAddress,
        { kind: "inline", value: newDatum },
        { [this.unit]: 1n, lovelace: 2_000_000n },
      );

    // Refund each requester
    for (const req of this.pendingRequests) {
      txBuilder = txBuilder.pay.ToAddress(this.walletAddress, {
        lovelace: req.lovelace - req.fee,
      });
    }

    const tx = await txBuilder
      .attach.SpendingValidator(this.validator.spendValidator)
      .addSignerKey(this.ownerKeyHash)
      .complete(COMPLETE_OPTS);

    await this.submitAndWait(tx);

    this.stateUtxo = await this.findStateUtxo();
    expect(this.stateUtxo!.datum).toBe(newDatum);
    this.root = newRoot;
    this.pendingRequests = [];
  }

  private async doMigrate(newValidator: Validator): Promise<void> {
    const oldValidator = this.validator;
    const oldUnit = this.unit;
    const newUnit = newValidator.policyId + this.assetName;

    const endRedeemer = encodeEndRedeemer();
    const burnRedeemer = encodeBurningRedeemer();
    const migrateRedeemer = encodeMigratingRedeemer(
      oldValidator.policyId,
      this.assetName,
    );
    const datum = encodeStateDatum(
      this.ownerKeyHash,
      this.root,
      this.maxFee,
    );

    const tx = await this.lucid
      .newTx()
      .collectFrom([this.stateUtxo!], endRedeemer)
      .mintAssets({ [oldUnit]: -1n }, burnRedeemer)
      .mintAssets({ [newUnit]: 1n }, migrateRedeemer)
      .pay.ToContract(
        newValidator.scriptAddress,
        { kind: "inline", value: datum },
        { [newUnit]: 1n, lovelace: 2_000_000n },
      )
      .attach.MintingPolicy(oldValidator.mintPolicy)
      .attach.MintingPolicy(newValidator.mintPolicy)
      .attach.SpendingValidator(oldValidator.spendValidator)
      .addSignerKey(this.ownerKeyHash)
      .complete(COMPLETE_OPTS);

    await this.submitAndWait(tx);

    // Verify: token at new address
    this.validator = newValidator;
    this.unit = newUnit;
    this.stateUtxo = await this.findStateUtxo();
    expect(this.stateUtxo!.datum).toBe(datum);

    // Verify: no token at old address
    const oldUtxos = await this.lucid.utxosAt(oldValidator.scriptAddress);
    const remaining = oldUtxos.find((u) => u.assets[oldUnit] === 1n);
    expect(remaining).toBeUndefined();
  }

  private async doEnd(): Promise<void> {
    const endRedeemer = encodeEndRedeemer();
    const burnRedeemer = encodeBurningRedeemer();

    const tx = await this.lucid
      .newTx()
      .collectFrom([this.stateUtxo!], endRedeemer)
      .mintAssets({ [this.unit]: -1n }, burnRedeemer)
      .attach.MintingPolicy(this.validator.mintPolicy)
      .attach.SpendingValidator(this.validator.spendValidator)
      .addSignerKey(this.ownerKeyHash)
      .complete(COMPLETE_OPTS);

    await this.submitAndWait(tx);

    // Verify: no token remaining
    const utxos = await this.lucid.utxosAt(this.validator.scriptAddress);
    const remaining = utxos.find((u) => u.assets[this.unit] === 1n);
    expect(remaining).toBeUndefined();
  }

  // --- Helpers ---

  private async submitAndWait(
    txBuilder: Awaited<ReturnType<ReturnType<LucidEvolution["newTx"]>["complete"]>>,
  ): Promise<string> {
    const signed = await txBuilder.sign.withWallet().complete();
    const hash = await signed.submit();
    expect(hash).toBeTruthy();
    await new Promise((r) => setTimeout(r, 5000));
    return hash;
  }

  private async findStateUtxo(): Promise<UTxO> {
    const utxos = await this.lucid.utxosAt(
      this.validator.scriptAddress,
    );
    const found = utxos.find((u) => u.assets[this.unit] === 1n);
    expect(found).toBeDefined();
    return found!;
  }
}

/** Create a fluent builder for an MPF Cage E2E scenario. */
export function cage(
  lucid: LucidEvolution,
  validator: Validator,
  ownerKeyHash: string,
  walletAddress: string,
): Cage {
  return new Cage(lucid, validator, ownerKeyHash, walletAddress);
}
