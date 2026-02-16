import { readFileSync } from "node:fs";
import {
  applyParamsToScript,
  mintingPolicyToId,
  validatorToAddress,
  type MintingPolicy,
  type SpendingValidator,
} from "@lucid-evolution/lucid";

interface Blueprint {
  preamble: { title: string; version: string };
  validators: Array<{
    title: string;
    compiledCode: string;
    hash: string;
  }>;
}

export function loadValidator(version: number) {
  const path = process.env.PLUTUS_JSON ?? "/app/plutus.json";
  const raw = readFileSync(path, "utf-8");
  const blueprint: Blueprint = JSON.parse(raw);

  const mintEntry = blueprint.validators.find(
    (v) => v.title === "cage.mpfCage.mint",
  );
  const spendEntry = blueprint.validators.find(
    (v) => v.title === "cage.mpfCage.spend",
  );

  if (!mintEntry || !spendEntry) {
    throw new Error("Validator not found in plutus.json");
  }

  const mintScript = applyParamsToScript(mintEntry.compiledCode, [
    BigInt(version),
  ]);
  const spendScript = applyParamsToScript(spendEntry.compiledCode, [
    BigInt(version),
  ]);

  const mintPolicy: MintingPolicy = {
    type: "PlutusV3",
    script: mintScript,
  };

  const spendValidator: SpendingValidator = {
    type: "PlutusV3",
    script: spendScript,
  };

  const policyId = mintingPolicyToId(mintPolicy);
  const scriptAddress = validatorToAddress("Custom", spendValidator);

  return {
    mintPolicy,
    spendValidator,
    policyId,
    scriptAddress,
  };
}
