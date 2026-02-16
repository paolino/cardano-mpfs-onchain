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

// UpdateRedeemer = End | Contribute(OutputReference) | Modify(List<Proof>) | Retract
// End is index 0
export function encodeEndRedeemer(): string {
  return Data.to(new Constr(0, []));
}
