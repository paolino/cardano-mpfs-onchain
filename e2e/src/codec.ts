import { Constr, Data, type UTxO } from "@lucid-evolution/lucid";

// CageDatum = RequestDatum(Request) | StateDatum(State)
// StateDatum is constructor index 1, State has fields { owner, root }
export function encodeStateDatum(
  owner: string,
  root: string,
): string {
  return Data.to(
    new Constr(1, [new Constr(0, [owner, root])]),
  );
}

// MintRedeemer = Minting(Mint) | Migrating(Migration) | Burning
// Minting is index 0, Mint has { asset: OutputReference }
// OutputReference = { transaction_id, output_index }
export function encodeMintRedeemer(utxo: UTxO): string {
  const outputRef = new Constr(0, [utxo.txHash, BigInt(utxo.outputIndex)]);
  const mint = new Constr(0, [outputRef]);
  return Data.to(new Constr(0, [mint]));
}

// Migrating is index 1, Migration has { oldPolicy, tokenId }
// TokenId has { assetName }
export function encodeMigratingRedeemer(
  oldPolicyId: string,
  assetName: string,
): string {
  const tokenId = new Constr(0, [assetName]);
  const migration = new Constr(0, [oldPolicyId, tokenId]);
  return Data.to(new Constr(1, [migration]));
}

// Burning is index 2 (no fields)
export function encodeBurningRedeemer(): string {
  return Data.to(new Constr(2, []));
}

// UpdateRedeemer = End(0) | Contribute(OutputReference)(1) | Modify(List<Proof>)(2) | Retract(3)

// End is index 0
export function encodeEndRedeemer(): string {
  return Data.to(new Constr(0, []));
}

// Contribute is index 1, takes an OutputReference pointing to the State UTxO
export function encodeContributeRedeemer(stateUtxo: UTxO): string {
  const outputRef = new Constr(0, [
    stateUtxo.txHash,
    BigInt(stateUtxo.outputIndex),
  ]);
  return Data.to(new Constr(1, [outputRef]));
}

// Modify is index 2, takes List<Proof> where Proof = List<ProofStep>
// For inserting into an empty MPF, proof is [] (empty list)
// So one insert: proofs = [[]] (one empty proof)
export function encodeModifyRedeemer(proofs: unknown[][]): string {
  return Data.to(new Constr(2, [proofs]));
}

// CageDatum = RequestDatum(Request)(0) | StateDatum(State)(1)
// Request { requestToken: TokenId, requestOwner: VerificationKeyHash,
//           requestKey: ByteArray, requestValue: Operation }
// TokenId { assetName: AssetName } = Constr(0, [assetName])
// Operation = Insert(ByteArray)(0) | Delete(ByteArray)(1) | Update(ByteArray, ByteArray)(2)
export function encodeRequestDatum(
  assetName: string,
  ownerHash: string,
  key: string,
  value: string,
): string {
  const tokenId = new Constr(0, [assetName]);
  const operation = new Constr(0, [value]); // Insert
  const request = new Constr(0, [tokenId, ownerHash, key, operation]);
  return Data.to(new Constr(0, [request]));
}

// Delete(ByteArray) is Operation index 1
export function encodeDeleteRequestDatum(
  assetName: string,
  ownerHash: string,
  key: string,
  value: string,
): string {
  const tokenId = new Constr(0, [assetName]);
  const operation = new Constr(1, [value]); // Delete
  const request = new Constr(0, [tokenId, ownerHash, key, operation]);
  return Data.to(new Constr(0, [request]));
}
