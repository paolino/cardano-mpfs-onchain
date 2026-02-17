import {
  Blockfrost,
  Lucid,
  type LucidEvolution,
  generateSeedPhrase,
} from "@lucid-evolution/lucid";
import { SLOT_CONFIG_NETWORK } from "@lucid-evolution/plutus";

const YACI_HOST = process.env.YACI_HOST ?? "localhost";

const STORE_URL = `http://${YACI_HOST}:8080/api/v1`;
const ADMIN_URL = `http://${YACI_HOST}:10000`;
const OGMIOS_URL = `http://${YACI_HOST}:1337`;

export async function waitForYaci(
  retries = 60,
  interval = 2000,
): Promise<void> {
  for (let i = 0; i < retries; i++) {
    try {
      const res = await fetch(`${STORE_URL}/epochs/latest`);
      if (res.ok) return;
    } catch {
      // not ready yet
    }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error("Yaci DevKit failed to become ready");
}

export async function topupAddress(
  address: string,
  adaAmount: number,
): Promise<void> {
  const res = await fetch(
    `${ADMIN_URL}/local-cluster/api/addresses/topup`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ address, adaAmount }),
    },
  );
  if (!res.ok) {
    throw new Error(`Topup failed: ${res.status} ${await res.text()}`);
  }
  // Wait for the topup to be visible
  await new Promise((r) => setTimeout(r, 3000));
}

// Ogmios purpose strings already match Lucid's expected redeemer tags:
// "mint", "spend", "publish", "withdraw", "vote", "propose"

// Evaluate a transaction using Ogmios HTTP API and transform to Lucid format
async function ogmiosEvaluateTx(txCbor: string): Promise<any> {
  const body = {
    jsonrpc: "2.0",
    method: "evaluateTransaction",
    params: { transaction: { cbor: txCbor } },
    id: null,
  };
  const res = await fetch(OGMIOS_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`Ogmios evaluateTx failed: ${res.status} - ${text}`);
  }
  const json = JSON.parse(text);
  if (json.error) {
    throw new Error(`Ogmios evaluation error: ${JSON.stringify(json.error)}`);
  }
  // Transform Ogmios format to what Lucid expects:
  // Ogmios: [{ validator: { index, purpose }, budget: { memory, cpu } }]
  // Lucid:  [{ redeemer_index, redeemer_tag, ex_units: { mem, steps } }]
  return json.result.map((item: any) => ({
    redeemer_index: item.validator.index,
    redeemer_tag: item.validator.purpose,
    ex_units: {
      mem: item.budget.memory,
      steps: item.budget.cpu,
    },
  }));
}

export async function initLucid(): Promise<LucidEvolution> {
  // Use Blockfrost (Yaci Store) as base provider
  const blockfrost = new Blockfrost(STORE_URL, "yaci");

  // Wrap the provider to use Ogmios for tx evaluation instead of local UPLC
  const provider = new Proxy(blockfrost, {
    get(target, prop, receiver) {
      if (prop === "evaluateTx") {
        return (txCbor: string) => ogmiosEvaluateTx(txCbor);
      }
      return Reflect.get(target, prop, receiver);
    },
  });

  // Lucid's Custom network initializes SLOT_CONFIG_NETWORK with slotLength: 0,
  // which causes division-by-zero when converting POSIX time to slots.
  // Query Yaci DevKit's genesis endpoint for the actual parameters.
  const genesisRes = await fetch(`${STORE_URL}/genesis`);
  const genesis = await genesisRes.json();
  SLOT_CONFIG_NETWORK["Custom"] = {
    zeroTime: genesis.system_start * 1000, // seconds → milliseconds
    zeroSlot: 0,
    slotLength: genesis.slot_length * 1000, // seconds → milliseconds
  };

  return Lucid(provider, "Custom");
}

export async function createTestWallet(lucid: LucidEvolution): Promise<{
  seedPhrase: string;
  address: string;
}> {
  const seedPhrase = generateSeedPhrase();
  lucid.selectWallet.fromSeed(seedPhrase);
  const address = await lucid.wallet().address();
  await topupAddress(address, 100);
  return { seedPhrase, address };
}
