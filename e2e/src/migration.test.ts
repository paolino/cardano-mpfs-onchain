import { describe, it, beforeAll } from "vitest";
import {
  type LucidEvolution,
  getAddressDetails,
} from "@lucid-evolution/lucid";
import { waitForYaci, initLucid, createTestWallet } from "./setup.js";
import { loadValidator } from "./blueprint.js";
import { cage } from "./cage.js";

const EMPTY_ROOT =
  "0000000000000000000000000000000000000000000000000000000000000000";
const MODIFIED_ROOT =
  "484dee386bcb51e285896271048baf6ea4396b2ee95be6fd29a92a0eeb8462ea";
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

  const PROCESS_TIME = 600_000n; // 10 minutes
  const RETRACT_TIME = 600_000n;

  it("mint and end on single version", async () => {
    await cage(
      lucid,
      loadValidator(0, PROCESS_TIME, RETRACT_TIME),
      ownerKeyHash,
      walletAddress,
    )
      .mint()
      .end();
  });

  it("modify with fee enforces refund to requester", async () => {
    await cage(
      lucid,
      loadValidator(0, PROCESS_TIME, RETRACT_TIME),
      ownerKeyHash,
      walletAddress,
    )
      .mint({ maxFee: 500_000n })
      .request(INSERT_KEY, INSERT_VALUE, { fee: 500_000n })
      .modify(MODIFIED_ROOT)
      .end();
  });

  it("migration preserves non-empty MPF root", async () => {
    await cage(
      lucid,
      loadValidator(0, PROCESS_TIME, RETRACT_TIME),
      ownerKeyHash,
      walletAddress,
    )
      .mint()
      .request(INSERT_KEY, INSERT_VALUE)
      .modify(MODIFIED_ROOT)
      .migrateTo(loadValidator(1, PROCESS_TIME, RETRACT_TIME))
      .deleteRequest(INSERT_KEY, INSERT_VALUE)
      .modify(EMPTY_ROOT)
      .migrateTo(loadValidator(2, PROCESS_TIME, RETRACT_TIME))
      .end();
  });

  it("reject discards request after retract window", async () => {
    const shortProcess = 10_000n;
    const shortRetract = 10_000n;
    await cage(
      lucid,
      loadValidator(0, shortProcess, shortRetract),
      ownerKeyHash,
      walletAddress,
    )
      .mint()
      .request(INSERT_KEY, INSERT_VALUE)
      .waitForPhase3()
      .reject()
      .end();
  });
});
