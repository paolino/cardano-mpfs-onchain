# Types & Encodings

All on-chain data structures are defined in
[`types.ak`](https://github.com/cardano-foundation/mpfs/blob/main/on_chain/validators/types.ak)
and compiled to Plutus V3 data encodings.

## Token Identity

```aiken
type TokenId = (PolicyId, AssetName)
```

The `AssetName` is derived from a consumed UTxO reference via
SHA2-256, guaranteeing global uniqueness.

## Datum

Every UTxO at the script address carries a `CageDatum`:

```aiken
type CageDatum {
    RequestDatum(Request)
    StateDatum(State)
}
```

### State

Attached to the UTxO that holds the MPF token.

```aiken
type State {
    owner: VerificationKeyHash
    root: ByteArray  -- 32-byte MPF root hash
}
```

| Field | Encoding | Description |
|---|---|---|
| `owner` | 28 bytes | Ed25519 public key hash of the token owner |
| `root` | 32 bytes | Current MPF root (Blake2b-256). Empty trie has a well-known null hash |

### Request

Attached to UTxOs representing pending modification requests.

```aiken
type Request {
    requestToken: TokenId
    requestOwner: VerificationKeyHash
    requestKey: ByteArray
    requestValue: Operation
}
```

| Field | Encoding | Description |
|---|---|---|
| `requestToken` | `(PolicyId, AssetName)` | Target MPF token |
| `requestOwner` | 28 bytes | Who can retract this request |
| `requestKey` | variable | Key in the MPF trie |
| `requestValue` | `Operation` | What to do with this key |

## Operations

```aiken
type Operation {
    Insert(ByteArray)               -- new_value
    Delete(ByteArray)               -- old_value
    Update(ByteArray, ByteArray)    -- old_value, new_value
}
```

| Constructor | Index | Fields | Description |
|---|---|---|---|
| `Insert` | 0 | `new_value` | Insert a new key-value pair (key must not exist) |
| `Delete` | 1 | `old_value` | Remove an existing key (must exist with this value) |
| `Update` | 2 | `old_value, new_value` | Change the value of an existing key |

## Redeemers

### Minting Redeemer

```aiken
type Mint {
    asset: OutputReference
}

type MintRedeemer {
    Minting(Mint)
    Burning
}
```

| Constructor | Index | Fields | Description |
|---|---|---|---|
| `Minting` | 0 | `Mint { asset: OutputReference }` | Boot a new token. `asset` identifies which UTxO to consume for unique naming |
| `Burning` | 1 | — | Burn the token (paired with `End` on the spending side) |

### Spending Redeemer

```aiken
type UpdateRedeemer {
    End
    Contribute(OutputReference)
    Modify(List<Proof>)
    Retract
}
```

| Constructor | Index | Fields | Description |
|---|---|---|---|
| `End` | 0 | — | Destroy the MPF instance |
| `Contribute` | 1 | `OutputReference` | Spend a request during update; points to the state UTxO |
| `Modify` | 2 | `List<Proof>` | Update the MPF root; one proof per request |
| `Retract` | 3 | — | Cancel a request and reclaim ADA |

## Plutus Data Encoding

All types compile to standard Plutus V3 `Data` constructors.
The constructor indices match the order listed above (0-indexed).

**Example — StateDatum on-chain encoding:**

```
Constr(1,           -- CageDatum.StateDatum
  [ Constr(0,       -- State
      [ Bytes(owner_pkh)
      , Bytes(root_hash)
      ])
  ])
```

**Example — RequestDatum with Insert:**

```
Constr(0,           -- CageDatum.RequestDatum
  [ Constr(0,       -- Request
      [ Constr(0, [Bytes(policy_id), Bytes(asset_name)])  -- TokenId
      , Bytes(owner_pkh)
      , Bytes(key)
      , Constr(0, [Bytes(new_value)])                     -- Insert
      ])
  ])
```
