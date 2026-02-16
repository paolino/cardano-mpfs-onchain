# Build plutus.json blueprint via Nix
build:
    nix build

# Enter development shell with aiken
develop:
    nix develop

# Build blueprint directly with aiken (requires aiken in PATH)
aiken-build:
    aiken build

# Run aiken tests
test:
    aiken check
